defmodule BullXGateway.ScopeWorker do
  @moduledoc """
  One process per `{{adapter, tenant}, scope_id}`. Serializes outbound
  dispatches against the adapter and owns the durable retry / DLQ state
  machine (RFC 0003 §7.5).

  Responsibilities:

    * Read pending rows from `gateway_dispatches` on `init/1` and classify
      them as resumable, re-queue-able, or dead-letter-stream-lost.
    * Invoke `adapter.deliver/2` inline for `:send` / `:edit` and
      `adapter.stream/3` inside `Task.Supervisor.async_nolink` for `:stream`.
    * Catch adapter exceptions and normalize them to `error.kind = "exception"`.
    * Classify adapter failures via `BullXGateway.RetryPolicy` and either
      schedule a retry or dead-letter the dispatch.
    * Publish `delivery.succeeded` / `delivery.failed` on `BullXGateway.SignalBus`.
    * Mark `BullXGateway.OutboundDeduper` on — and **only** on — terminal
      success.
    * Monitor the adapter subtree anchor pid (when the adapter exposes it
      through `context`). On adapter DOWN, kill any in-flight `:stream` Task
      and take the terminal path with `error.kind = "adapter_restarted"`.
    * Hibernate after 60 s of idle and terminate after 5 min.
  """

  use GenServer, restart: :transient

  require Logger

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Outcome
  alias BullXGateway.Dispatcher
  alias BullXGateway.OutboundDeduper
  alias BullXGateway.RetryPolicy
  alias BullXGateway.ScopeRegistry
  alias BullXGateway.Telemetry
  alias Jido.Signal
  alias Jido.Signal.Bus

  @default_hibernate_ms 60_000
  @default_terminate_ms 5 * 60_000

  @type channel :: BullXGateway.Delivery.channel()

  def child_spec({channel, scope_id, opts}) do
    %{
      id: {__MODULE__, channel, scope_id},
      start: {__MODULE__, :start_link, [{channel, scope_id, opts}]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link({channel, scope_id, opts}) do
    GenServer.start_link(__MODULE__, {channel, scope_id, opts},
      name: ScopeRegistry.via(channel, scope_id)
    )
  end

  @doc """
  Enqueue a delivery on this scope's worker.
  """
  @spec enqueue(channel(), String.t(), String.t()) :: :ok
  def enqueue(channel, scope_id, delivery_id) do
    case Dispatcher.ensure_started(channel, scope_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:enqueue, delivery_id})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancel an in-flight `:stream`. Returns `:ok` when the intent is accepted
  (even if the adapter has already finished), `{:error, :not_found}` when no
  stream with `delivery_id` is in flight on this node.
  """
  @spec cancel_stream(String.t()) :: :ok | {:error, :not_found}
  def cancel_stream(delivery_id) when is_binary(delivery_id) do
    case find_worker_for_delivery(delivery_id) do
      {:ok, pid} -> GenServer.call(pid, {:cancel_stream, delivery_id})
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def init({channel, scope_id, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      channel: channel,
      scope_id: scope_id,
      adapter_module: nil,
      adapter_config: %{},
      adapter_anchor_pid: nil,
      adapter_monitor_ref: nil,
      retry_policy: RetryPolicy.default(),
      status: :idle,
      queue: [],
      retry_timers: %{},
      stream_attempts: %{},
      stream_intent: nil,
      hibernate_ms: Keyword.get(opts, :hibernate_ms, @default_hibernate_ms),
      terminate_ms: Keyword.get(opts, :terminate_ms, @default_terminate_ms),
      hibernate_timer: nil,
      terminate_timer: nil
    }

    state = load_adapter_entry(state)
    send(self(), :recover_pending)

    {:ok, reset_idle_timers(state)}
  end

  # --- casts ---

  @impl true
  def handle_cast({:enqueue, delivery_id}, state) do
    state = cancel_idle_timers(state)

    if state.status == :idle do
      {:noreply, start_next(%{state | queue: [delivery_id]})}
    else
      {:noreply, %{state | queue: state.queue ++ [delivery_id]}}
    end
  end

  # --- calls ---

  @impl true
  def handle_call({:cancel_stream, delivery_id}, _from, state) do
    case state.status do
      {:running, ^delivery_id, {:stream, task}} ->
        cancelled_state = shutdown_stream_task(state, task, :user_cancel)
        {:reply, :ok, cancelled_state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- info ---

  @impl true
  def handle_info(:recover_pending, state) do
    state = recover_pending_dispatches(state)
    {:noreply, state}
  end

  def handle_info({:run, delivery_id}, state) do
    state = cancel_idle_timers(state)
    state = %{state | retry_timers: Map.delete(state.retry_timers, delivery_id)}

    case state.status do
      :idle ->
        {:noreply, attempt_delivery(state, delivery_id)}

      {:running, _other_id, _} ->
        {:noreply, %{state | queue: state.queue ++ [delivery_id]}}
    end
  end

  def handle_info({ref, result}, %{status: {:running, id, {:stream, %Task{ref: ref}}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finalize_stream(state, id, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{status: {:running, id, {:stream, %Task{ref: ref}}}} = state
      ) do
    error_map = synthesize_stream_error(state.stream_intent, reason)
    {:noreply, finalize_stream(state, id, {:error, error_map})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{adapter_monitor_ref: ref} = state) do
    new_state = %{state | adapter_monitor_ref: nil, adapter_anchor_pid: nil}

    case new_state.status do
      {:running, _id, {:stream, task}} ->
        {:noreply, shutdown_stream_task(new_state, task, :adapter_down)}

      _ ->
        {:noreply, new_state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:hibernate_idle, state) do
    if state.status == :idle and state.queue == [] do
      {:noreply, state, :hibernate}
    else
      {:noreply, state}
    end
  end

  def handle_info(:terminate_idle, state) do
    if state.status == :idle and state.queue == [] and map_size(state.retry_timers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, reset_idle_timers(state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_idle_timers(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Core pipeline
  # ---------------------------------------------------------------------------

  defp attempt_delivery(state, delivery_id) do
    with {:ok, dispatch} <- ControlPlane.fetch_dispatch(delivery_id),
         next_attempt = dispatch.attempts + 1,
         {:ok, _updated} <-
           ControlPlane.update_dispatch(delivery_id, %{
             status: "running",
             attempts: next_attempt
           }),
         :ok <-
           ControlPlane.put_attempt(%{
             id: attempt_id(delivery_id, next_attempt),
             dispatch_id: delivery_id,
             attempt: next_attempt,
             started_at: DateTime.utc_now(),
             status: "running"
           }) do
      run_adapter(state, dispatch, next_attempt)
    else
      :error ->
        # Dispatch row vanished (retention or stale cast). Drop quietly.
        advance_next(%{state | status: :idle})

      {:error, reason} ->
        Logger.warning(
          "BullXGateway.ScopeWorker attempt pre-flight failed for #{delivery_id}: #{inspect(reason)}"
        )

        advance_next(%{state | status: :idle})
    end
  end

  defp run_adapter(state, dispatch, attempt_num) do
    delivery = decode_delivery(dispatch)
    ctx = build_context(state)

    case delivery.op do
      op when op in [:send, :edit] ->
        run_sync(state, delivery, attempt_num, ctx)

      :stream ->
        run_stream(state, delivery, attempt_num, ctx)
    end
  end

  defp run_sync(state, delivery, attempt_num, ctx) do
    state = %{state | status: {:running, delivery.id, :send_edit}, stream_intent: nil}

    result =
      safe_adapter_call(fn ->
        state.adapter_module.deliver(delivery, ctx)
      end)

    handle_attempt_result(state, delivery, attempt_num, result)
  end

  defp run_stream(state, delivery, attempt_num, ctx) do
    enumerable = delivery.content
    adapter_module = state.adapter_module

    task =
      Task.Supervisor.async_nolink(Dispatcher.task_supervisor_name(), fn ->
        safe_adapter_call(fn -> adapter_module.stream(delivery, enumerable, ctx) end)
      end)

    # Stash the attempt number under a distinct key so finalization can find
    # it without re-fetching the Dispatch row.
    %{
      state
      | status: {:running, delivery.id, {:stream, task}},
        stream_intent: nil,
        stream_attempts: Map.put(state.stream_attempts, delivery.id, attempt_num)
    }
  end

  defp finalize_stream(state, delivery_id, result) do
    {attempt_num, state} =
      case Map.pop(state.stream_attempts, delivery_id) do
        {nil, _} -> {1, state}
        {num, map} -> {num, %{state | stream_attempts: map}}
      end

    state = %{state | stream_intent: nil}

    case ControlPlane.fetch_dispatch(delivery_id) do
      {:ok, dispatch} ->
        delivery = decode_delivery(dispatch)
        handle_attempt_result(state, delivery, attempt_num, result)

      :error ->
        Logger.warning(
          "BullXGateway.ScopeWorker stream dispatch vanished before finalization: #{delivery_id}"
        )

        advance_next(%{state | status: :idle})
    end
  end

  defp handle_attempt_result(state, delivery, attempt_num, result) do
    case normalize_result(delivery, result) do
      {:ok, %Outcome{} = outcome} ->
        record_success(state, delivery, attempt_num, outcome)

      {:error, error_map} ->
        record_failure(state, delivery, attempt_num, error_map)
    end
  end

  # A success from the adapter must match `adapter_success_t`
  # (status :sent | :degraded). `Outcome{status: :failed}` is forbidden.
  defp normalize_result(delivery, {:ok, %Outcome{status: status} = outcome})
       when status in [:sent, :degraded] do
    {:ok, %{outcome | delivery_id: delivery.id}}
  end

  defp normalize_result(delivery, {:ok, %Outcome{status: :failed}}) do
    {:error,
     %{
       "kind" => "contract",
       "message" =>
         "Adapter returned Outcome{status: :failed}; only ScopeWorker may produce :failed",
       "details" => %{"delivery_id" => delivery.id}
     }}
  end

  defp normalize_result(_delivery, {:ok, other}) do
    {:error,
     %{
       "kind" => "contract",
       "message" => "Adapter returned invalid success shape",
       "details" => %{"got" => inspect(other)}
     }}
  end

  defp normalize_result(_delivery, {:error, error_map}) when is_map(error_map) do
    {:error, error_map}
  end

  defp normalize_result(_delivery, other) do
    {:error,
     %{
       "kind" => "contract",
       "message" => "Adapter returned a value that is neither {:ok, _} nor {:error, _}",
       "details" => %{"got" => inspect(other)}
     }}
  end

  defp record_success(state, delivery, attempt_num, %Outcome{} = outcome) do
    now = DateTime.utc_now()
    attempt_id = attempt_id(delivery.id, attempt_num)

    case ControlPlane.transaction(fn store ->
           with :ok <-
                  store.put_attempt(%{
                    id: attempt_id,
                    dispatch_id: delivery.id,
                    attempt: attempt_num,
                    started_at: now,
                    finished_at: now,
                    status: "completed",
                    outcome: Outcome.to_signal_data(outcome)
                  }),
                :ok <- store.delete_dispatch(delivery.id) do
             :ok
           end
         end) do
      {:ok, :ok} ->
        publish_outcome_signal(state, delivery, outcome)
        OutboundDeduper.mark_success(delivery.id, outcome)

        emit_telemetry(:delivered, state, delivery, %{attempts: attempt_num}, %{
          outcome: outcome.status
        })

        advance_next(%{state | status: :idle})

      {:error, reason} ->
        Logger.error(
          "BullXGateway.ScopeWorker failed to persist success for #{delivery.id}: #{inspect(reason)}"
        )

        # The success was not recorded transactionally. Classify as a fresh
        # retryable `:network`-style failure so the state machine can recover.
        error_map = %{
          "kind" => "exception",
          "message" => "store transaction failed",
          "details" => %{"reason" => inspect(reason)}
        }

        record_failure(state, delivery, attempt_num, error_map)
    end
  end

  defp record_failure(state, delivery, attempt_num, error_map) do
    case RetryPolicy.classify(state.retry_policy, error_map, attempt_num) do
      :retry ->
        schedule_retry(state, delivery, attempt_num, error_map)

      :terminal ->
        dead_letter(state, delivery, attempt_num, error_map)
    end
  end

  defp schedule_retry(state, delivery, attempt_num, error_map) do
    backoff_ms = RetryPolicy.backoff_ms(state.retry_policy, error_map, attempt_num)
    available_at = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)
    attempt_id = attempt_id(delivery.id, attempt_num)

    :ok =
      ControlPlane.put_attempt(%{
        id: attempt_id,
        dispatch_id: delivery.id,
        attempt: attempt_num,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        status: "failed",
        error: error_map
      })
      |> ok_or_log(delivery.id, :put_attempt_failed)

    case ControlPlane.update_dispatch(delivery.id, %{
           status: "retry_scheduled",
           available_at: available_at,
           last_error: error_map
         }) do
      {:ok, _dispatch} ->
        timer_ref = Process.send_after(self(), {:run, delivery.id}, backoff_ms)

        emit_telemetry(
          :retry_scheduled,
          state,
          delivery,
          %{attempts: attempt_num, backoff_ms: backoff_ms},
          %{
            kind: error_map["kind"]
          }
        )

        new_timers = Map.put(state.retry_timers, delivery.id, timer_ref)

        advance_next(%{state | status: :idle, retry_timers: new_timers})

      {:error, reason} ->
        Logger.error(
          "BullXGateway.ScopeWorker retry_scheduled update failed for #{delivery.id}: #{inspect(reason)}"
        )

        # Fall back to terminal dead-letter so the dispatch does not get
        # stuck in :running on the UNLOGGED row.
        dead_letter(state, delivery, attempt_num, error_map)
    end
  end

  defp dead_letter(state, delivery, attempt_num, error_map) do
    now = DateTime.utc_now()
    attempt_id = attempt_id(delivery.id, attempt_num)
    outcome = Outcome.new_failure(delivery.id, error_map)

    case ControlPlane.transaction(fn store ->
           with :ok <-
                  store.put_attempt(%{
                    id: attempt_id,
                    dispatch_id: delivery.id,
                    attempt: attempt_num,
                    started_at: now,
                    finished_at: now,
                    status: "failed",
                    error: error_map
                  }),
                :ok <-
                  store.put_dead_letter(%{
                    dispatch_id: delivery.id,
                    op: Atom.to_string(delivery.op),
                    channel_adapter: Atom.to_string(elem(delivery.channel, 0)),
                    channel_tenant: elem(delivery.channel, 1),
                    scope_id: delivery.scope_id,
                    thread_id: delivery.thread_id,
                    caused_by_signal_id: delivery.caused_by_signal_id,
                    payload: encode_delivery_payload(delivery),
                    final_error: error_map,
                    attempts_total: attempt_num,
                    dead_lettered_at: now
                  }),
                :ok <- store.delete_dispatch(delivery.id) do
             :ok
           end
         end) do
      {:ok, :ok} ->
        publish_outcome_signal(state, delivery, outcome)

        emit_telemetry(:dead_lettered, state, delivery, %{attempts: attempt_num}, %{
          kind: error_map["kind"]
        })

        advance_next(%{state | status: :idle})

      {:error, reason} ->
        Logger.error(
          "BullXGateway.ScopeWorker dead-letter transaction failed for #{delivery.id}: #{inspect(reason)}"
        )

        advance_next(%{state | status: :idle})
    end
  end

  # ---------------------------------------------------------------------------
  # Queue / idle lifecycle
  # ---------------------------------------------------------------------------

  defp advance_next(%{queue: []} = state), do: reset_idle_timers(state)

  defp advance_next(%{queue: [head | rest]} = state) do
    send(self(), {:run, head})
    %{state | queue: rest}
  end

  defp start_next(state) do
    advance_next(state)
  end

  defp reset_idle_timers(state) do
    state = cancel_idle_timers(state)

    %{
      state
      | hibernate_timer: Process.send_after(self(), :hibernate_idle, state.hibernate_ms),
        terminate_timer: Process.send_after(self(), :terminate_idle, state.terminate_ms)
    }
  end

  defp cancel_idle_timers(state) do
    if state.hibernate_timer, do: Process.cancel_timer(state.hibernate_timer)
    if state.terminate_timer, do: Process.cancel_timer(state.terminate_timer)
    %{state | hibernate_timer: nil, terminate_timer: nil}
  end

  # ---------------------------------------------------------------------------
  # Crash recovery
  # ---------------------------------------------------------------------------

  defp recover_pending_dispatches(state) do
    case ControlPlane.list_dispatches_by_scope(state.channel, state.scope_id, [
           "queued",
           "retry_scheduled",
           "running"
         ]) do
      {:ok, rows} ->
        Enum.reduce(rows, state, &recover_row/2)

      _ ->
        state
    end
  end

  defp recover_row(row, state) do
    case {row.status, row.op} do
      {"queued", _} ->
        queue_after(state, row.id, delay_ms(row.available_at))

      {"retry_scheduled", _} ->
        queue_after(state, row.id, delay_ms(row.available_at))

      {"running", op} when op in ["send", "edit"] ->
        # "crash interrupted" path; re-queue immediately.
        case ControlPlane.update_dispatch(row.id, %{
               status: "queued",
               available_at: DateTime.utc_now()
             }) do
          {:ok, _} -> queue_after(state, row.id, 0)
          _ -> state
        end

      {"running", "stream"} ->
        dead_letter_stream_lost(state, row)

      _ ->
        state
    end
  end

  defp queue_after(state, delivery_id, 0) do
    send(self(), {:run, delivery_id})
    cancel_idle_timers(state)
  end

  defp queue_after(state, delivery_id, delay_ms) do
    timer_ref = Process.send_after(self(), {:run, delivery_id}, delay_ms)
    %{state | retry_timers: Map.put(state.retry_timers, delivery_id, timer_ref)}
  end

  defp delay_ms(nil), do: 0

  defp delay_ms(%DateTime{} = available_at) do
    diff = DateTime.diff(available_at, DateTime.utc_now(), :millisecond)
    max(diff, 0)
  end

  defp dead_letter_stream_lost(state, row) do
    attempts_total = row.attempts

    error_map = %{
      "kind" => "stream_lost",
      "message" => "Stream interrupted by crash; enumerable not durable"
    }

    now = DateTime.utc_now()
    attempt_id = attempt_id(row.id, attempts_total)

    delivery_stub = %{
      id: row.id,
      op: :stream,
      channel: state.channel,
      scope_id: row.scope_id,
      thread_id: row.thread_id,
      caused_by_signal_id: row.caused_by_signal_id
    }

    outcome = Outcome.new_failure(row.id, error_map)

    _ =
      ControlPlane.transaction(fn store ->
        _ =
          store.put_attempt(%{
            id: attempt_id,
            dispatch_id: row.id,
            attempt: max(attempts_total, 1),
            started_at: now,
            finished_at: now,
            status: "failed",
            error: error_map
          })

        _ =
          store.put_dead_letter(%{
            dispatch_id: row.id,
            op: row.op,
            channel_adapter: row.channel_adapter,
            channel_tenant: row.channel_tenant,
            scope_id: row.scope_id,
            thread_id: row.thread_id,
            caused_by_signal_id: row.caused_by_signal_id,
            payload: row.payload,
            final_error: error_map,
            attempts_total: attempts_total,
            dead_lettered_at: now
          })

        store.delete_dispatch(row.id)
      end)

    publish_outcome_signal(state, delivery_stub, outcome)

    emit_telemetry(:stream_lost_recovered, state, delivery_stub, %{attempts: attempts_total}, %{})
    state
  end

  # ---------------------------------------------------------------------------
  # Stream cancellation
  # ---------------------------------------------------------------------------

  defp shutdown_stream_task(state, task, reason) do
    marked_state = %{state | stream_intent: reason}

    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        # Adapter finished before we killed it; treat the return value as
        # authoritative (adapter may have produced a cancel error itself).
        {:running, id, _} = marked_state.status
        finalize_stream(marked_state, id, result)

      {:exit, exit_reason} ->
        {:running, id, _} = marked_state.status
        error_map = synthesize_stream_error(reason, exit_reason)
        finalize_stream(marked_state, id, {:error, error_map})

      nil ->
        {:running, id, _} = marked_state.status
        error_map = synthesize_stream_error(reason, :killed)
        finalize_stream(marked_state, id, {:error, error_map})
    end
  end

  defp synthesize_stream_error(:user_cancel, _reason) do
    %{"kind" => "stream_cancelled", "message" => "Stream cancelled by operator"}
  end

  defp synthesize_stream_error(:adapter_down, _reason) do
    %{"kind" => "adapter_restarted", "message" => "Adapter subtree DOWN during stream"}
  end

  defp synthesize_stream_error(_, reason) do
    %{"kind" => "exception", "message" => "Stream task exited: #{inspect(reason)}"}
  end

  # ---------------------------------------------------------------------------
  # Adapter / bus / telemetry
  # ---------------------------------------------------------------------------

  defp load_adapter_entry(state) do
    case AdapterRegistry.lookup(state.channel) do
      {:ok, entry} ->
        module = entry.module
        config = entry.config

        policy = RetryPolicy.build(Map.get(config, :retry_policy, %{}))
        {anchor_pid, monitor_ref} = maybe_monitor_adapter(Map.get(config, :anchor_pid))

        %{
          state
          | adapter_module: module,
            adapter_config: config,
            adapter_anchor_pid: anchor_pid,
            adapter_monitor_ref: monitor_ref,
            retry_policy: policy
        }

      :error ->
        state
    end
  end

  defp maybe_monitor_adapter(pid) when is_pid(pid) do
    {pid, Process.monitor(pid)}
  end

  defp maybe_monitor_adapter(_), do: {nil, nil}

  defp build_context(state) do
    telemetry = %{
      channel: state.channel,
      scope_id: state.scope_id
    }

    ctx = %{
      channel: state.channel,
      config: state.adapter_config,
      telemetry: telemetry
    }

    if state.adapter_anchor_pid,
      do: Map.put(ctx, :anchor_pid, state.adapter_anchor_pid),
      else: ctx
  end

  defp safe_adapter_call(fun) do
    try do
      fun.()
    rescue
      e ->
        {:error,
         %{
           "kind" => "exception",
           "message" => Exception.message(e),
           "details" => %{"module" => exception_module(e)}
         }}
    catch
      kind, reason ->
        {:error,
         %{
           "kind" => "exception",
           "message" => "#{kind}: #{inspect(reason)}"
         }}
    end
  end

  defp exception_module(%mod{}), do: Atom.to_string(mod)
  defp exception_module(_), do: "unknown"

  defp publish_outcome_signal(state, delivery, %Outcome{} = outcome) do
    {adapter, tenant} = state.channel

    type =
      case outcome.status do
        :failed -> "com.agentbull.x.delivery.failed"
        _ -> "com.agentbull.x.delivery.succeeded"
      end

    extensions =
      %{
        "bullx_channel_adapter" => Atom.to_string(adapter),
        "bullx_channel_tenant" => tenant
      }

    extensions =
      case Map.get(delivery, :caused_by_signal_id) do
        nil -> extensions
        id -> Map.put(extensions, "bullx_caused_by", id)
      end

    subject = render_subject(adapter, state.scope_id, Map.get(delivery, :thread_id))

    case Signal.new(%{
           id: Signal.ID.generate!(),
           source: "bullx://gateway/#{adapter}/#{tenant}",
           type: type,
           subject: subject,
           time: DateTime.to_iso8601(DateTime.utc_now()),
           datacontenttype: "application/json",
           data: Outcome.to_signal_data(outcome),
           extensions: extensions
         }) do
      {:ok, signal} ->
        case Bus.publish(BullXGateway.SignalBus, [signal]) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("delivery outcome bus publish failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("delivery outcome signal build failed: #{inspect(reason)}")
    end
  end

  defp render_subject(adapter, scope_id, nil), do: "#{adapter}:#{scope_id}"
  defp render_subject(adapter, scope_id, thread_id), do: "#{adapter}:#{scope_id}:#{thread_id}"

  defp emit_telemetry(event, state, delivery, measurements, metadata) do
    Telemetry.emit(
      [:bullx, :gateway, :delivery, event],
      measurements,
      Map.merge(metadata, %{
        channel: state.channel,
        scope_id: state.scope_id,
        op: Map.get(delivery, :op),
        delivery_id: Map.get(delivery, :id)
      })
    )
  end

  # ---------------------------------------------------------------------------
  # Delivery encoding
  # ---------------------------------------------------------------------------

  defp decode_delivery(dispatch) do
    payload = dispatch.payload || %{}
    adapter_atom = String.to_existing_atom(dispatch.channel_adapter)

    %Delivery{
      id: dispatch.id,
      op: string_to_op(dispatch.op),
      channel: {adapter_atom, dispatch.channel_tenant},
      scope_id: dispatch.scope_id,
      thread_id: dispatch.thread_id,
      reply_to_external_id: payload["reply_to_external_id"],
      target_external_id: payload["target_external_id"],
      content: decode_content(payload["content"], dispatch.op),
      caused_by_signal_id: dispatch.caused_by_signal_id,
      extensions: payload["extensions"] || %{}
    }
  end

  defp string_to_op("send"), do: :send
  defp string_to_op("edit"), do: :edit
  defp string_to_op("stream"), do: :stream

  defp decode_content(_content, "stream"), do: nil

  defp decode_content(nil, _op), do: nil

  defp decode_content(%{"kind" => kind, "body" => body}, _op) do
    %BullXGateway.Delivery.Content{kind: String.to_existing_atom(kind), body: body}
  end

  defp decode_content(_, _), do: nil

  @doc false
  def encode_delivery_payload(%Delivery{} = delivery) do
    content =
      case delivery.op do
        :stream -> nil
        _ -> encode_content(delivery.content)
      end

    %{
      "reply_to_external_id" => delivery.reply_to_external_id,
      "target_external_id" => delivery.target_external_id,
      "content" => content,
      "extensions" => delivery.extensions
    }
  end

  defp encode_content(nil), do: nil

  defp encode_content(%BullXGateway.Delivery.Content{kind: kind, body: body}) do
    %{"kind" => Atom.to_string(kind), "body" => body}
  end

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  defp attempt_id(delivery_id, attempt_num), do: "#{delivery_id}:#{attempt_num}"

  defp ok_or_log(:ok, _delivery_id, _event), do: :ok

  defp ok_or_log({:error, reason}, delivery_id, event) do
    Logger.warning("BullXGateway.ScopeWorker #{event} for #{delivery_id}: #{inspect(reason)}")
    :error
  end

  defp find_worker_for_delivery(delivery_id) do
    case ControlPlane.fetch_dispatch(delivery_id) do
      {:ok, dispatch} ->
        channel = {String.to_existing_atom(dispatch.channel_adapter), dispatch.channel_tenant}

        case ScopeRegistry.whereis(channel, dispatch.scope_id) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> :error
        end

      :error ->
        :error
    end
  end
end
