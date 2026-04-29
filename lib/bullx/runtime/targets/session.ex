defmodule BullX.Runtime.Targets.Session do
  @moduledoc false

  use GenServer

  alias BullX.Runtime.Targets.Target
  alias BullX.Runtime.Targets.SessionRegistry
  alias BullXAIAgent.Context, as: AIContext
  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Content
  alias Jido.Signal

  @idle_timeout_ms 30 * 60 * 1_000
  @turn_timeout_ms 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: SessionRegistry.via_tuple(session_key))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec turn(GenServer.server(), map(), Signal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def turn(server, resolution, %Signal{} = signal, opts \\ []) do
    timeout = Keyword.get(opts, :turn_timeout_ms, @turn_timeout_ms)
    GenServer.call(server, {:turn, resolution, signal, opts}, timeout)
  end

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)

    :telemetry.execute(
      [:bullx, :runtime, :targets, :session_started],
      %{count: 1},
      %{session_key: session_key}
    )

    idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, @idle_timeout_ms)

    {:ok, %{session_key: session_key, context: AIContext.new(), idle_timeout_ms: idle_timeout_ms},
     idle_timeout_ms}
  end

  @impl true
  def handle_call({:turn, resolution, %Signal{} = signal, opts}, _from, state) do
    result = run_turn(resolution, signal, state, opts)

    case result do
      {:ok, reply, next_state} ->
        {:reply, {:ok, reply}, next_state, next_state.idle_timeout_ms}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state, next_state.idle_timeout_ms}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    :telemetry.execute(
      [:bullx, :runtime, :targets, :session_stopped],
      %{count: 1},
      %{session_key: state.session_key, reason: :idle_timeout}
    )

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, state, state.idle_timeout_ms}
  end

  defp run_turn(%{target: %Target{} = target} = resolution, %Signal{} = signal, state, opts) do
    metadata = telemetry_metadata(target, resolution.route, signal)

    with :ok <- ensure_duplex(signal, metadata),
         {:ok, user_text} <- extract_user_text(signal, metadata) do
      :telemetry.execute([:bullx, :runtime, :targets, :turn_started], %{count: 1}, metadata)

      started_at = System.monotonic_time(:millisecond)
      kind_module = Keyword.fetch!(opts, :kind_module)

      input = %{
        target: target,
        context: state.context,
        user_text: user_text,
        refs: %{
          signal_id: signal.id,
          route_key: route_key(resolution.route),
          target_key: target.key
        }
      }

      case kind_module.run(input, opts) do
        {:ok, %{answer: answer, context: %AIContext{} = context} = output}
        when is_binary(answer) ->
          next_state = %{state | context: context}

          :telemetry.execute(
            [:bullx, :runtime, :targets, :turn_completed],
            %{duration_ms: System.monotonic_time(:millisecond) - started_at},
            metadata
          )

          case deliver_reply(signal, target, resolution.route, answer, opts) do
            {:ok, delivery_id} -> {:ok, Map.put(output, :delivery_id, delivery_id), next_state}
            {:error, reason} -> {:error, {:reply_failed, reason}, next_state}
          end

        {:error, reason} ->
          :telemetry.execute(
            [:bullx, :runtime, :targets, :turn_failed],
            %{duration_ms: System.monotonic_time(:millisecond) - started_at},
            Map.put(metadata, :failure_kind, failure_kind(reason))
          )

          {:error, reason, state}
      end
    else
      {:skip, reason} ->
        {:ok, %{skipped: reason}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp ensure_duplex(
         %Signal{data: %{"duplex" => true, "reply_channel" => reply_channel}},
         _metadata
       )
       when is_map(reply_channel),
       do: :ok

  defp ensure_duplex(%Signal{} = _signal, metadata) do
    :telemetry.execute(
      [:bullx, :runtime, :targets, :route_skipped],
      %{count: 1},
      Map.put(metadata, :reason, :not_duplex)
    )

    {:skip, :not_duplex}
  end

  defp extract_user_text(%Signal{data: %{"content" => content}}, metadata)
       when is_list(content) do
    text =
      content
      |> Enum.flat_map(&content_text/1)
      |> Enum.join("\n")
      |> String.trim()

    case text do
      "" ->
        :telemetry.execute(
          [:bullx, :runtime, :targets, :route_skipped],
          %{count: 1},
          Map.put(metadata, :reason, :empty_text)
        )

        {:skip, :empty_text}

      value ->
        {:ok, value}
    end
  end

  defp extract_user_text(_signal, metadata) do
    :telemetry.execute(
      [:bullx, :runtime, :targets, :route_skipped],
      %{count: 1},
      Map.put(metadata, :reason, :missing_content)
    )

    {:skip, :missing_content}
  end

  defp content_text(block) when is_map(block) do
    kind = Map.get(block, "kind", Map.get(block, :kind))
    body = Map.get(block, "body", Map.get(block, :body, %{}))

    case {kind, body} do
      {kind, body} when kind in ["text", :text] and is_map(body) ->
        string_value(Map.get(body, "text", Map.get(body, :text)))

      {_kind, body} when is_map(body) ->
        string_value(Map.get(body, "fallback_text", Map.get(body, :fallback_text)))

      _ ->
        []
    end
  end

  defp content_text(_block), do: []

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      text -> [text]
    end
  end

  defp string_value(_value), do: []

  defp deliver_reply(%Signal{} = signal, %Target{} = target, route, answer, opts) do
    reply_channel = signal.data["reply_channel"]

    with {:ok, adapter} <- adapter_atom(reply_channel["adapter"]),
         {:ok, delivery} <- build_delivery(signal, reply_channel, adapter, target, route, answer),
         {:ok, delivery_id} <- gateway_module(opts).deliver(delivery) do
      :telemetry.execute(
        [:bullx, :runtime, :targets, :reply_enqueued],
        %{count: 1},
        telemetry_metadata(target, route, signal)
      )

      {:ok, delivery_id}
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:bullx, :runtime, :targets, :reply_failed],
          %{count: 1},
          signal
          |> telemetry_metadata(target, route)
          |> Map.put(:failure_kind, failure_kind(reason))
        )

        error
    end
  end

  defp build_delivery(
         %Signal{} = signal,
         reply_channel,
         adapter,
         %Target{} = target,
         route,
         answer
       ) do
    delivery = %Delivery{
      id: BullX.Ext.gen_uuid_v7(),
      op: :send,
      channel: {adapter, reply_channel["channel_id"]},
      scope_id: reply_channel["scope_id"],
      thread_id: reply_channel["thread_id"],
      reply_to_external_id: signal.data["reply_to_external_id"],
      caused_by_signal_id: signal.id,
      content: %Content{kind: :text, body: %{"text" => answer}},
      extensions: %{
        "bullx_runtime_target" => target.key,
        "bullx_runtime_route" => route_key(route)
      }
    }

    case Delivery.validate(delivery) do
      :ok -> {:ok, delivery}
      {:error, reason} -> {:error, {:invalid_delivery, reason}}
    end
  end

  defp adapter_atom(adapter) when is_atom(adapter), do: {:ok, adapter}

  defp adapter_atom(adapter) when is_binary(adapter) do
    {:ok, String.to_existing_atom(adapter)}
  rescue
    ArgumentError -> {:error, {:unknown_adapter, adapter}}
  end

  defp adapter_atom(adapter), do: {:error, {:invalid_adapter, adapter}}

  defp gateway_module(opts), do: Keyword.get(opts, :gateway_module, BullXGateway)

  defp telemetry_metadata(%Target{} = target, route, %Signal{} = signal) do
    %{
      target_key: target.key,
      target_kind: target.kind,
      route_key: route_key(route),
      adapter: get_in(signal.extensions || %{}, ["bullx_channel_adapter"]),
      channel_id: get_in(signal.extensions || %{}, ["bullx_channel_id"]),
      scope_id: get_in(signal.data || %{}, ["scope_id"]),
      thread_id: get_in(signal.data || %{}, ["thread_id"]),
      signal_id: signal.id
    }
  end

  defp telemetry_metadata(%Signal{} = signal, %Target{} = target, route),
    do: telemetry_metadata(target, route, signal)

  defp route_key(%{key: key}), do: key
  defp route_key(:main), do: "main"

  defp failure_kind({kind, _detail}) when is_atom(kind), do: kind
  defp failure_kind(kind) when is_atom(kind), do: kind
  defp failure_kind(_reason), do: :error
end
