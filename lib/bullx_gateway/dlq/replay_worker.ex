defmodule BullXGateway.DLQ.ReplayWorker do
  @moduledoc """
  Serializes DLQ replay operations for one partition.

  `ReplaySupervisor` hashes `dispatch_id` into a partition index; each worker
  processes one replay at a time, so a second `replay_dead_letter/1` call
  against the same dispatch (either intentional or accidental) queues behind
  the first.
  """

  use GenServer

  require Logger

  alias BullXGateway.ControlPlane
  alias BullXGateway.DLQ.ReplaySupervisor
  alias BullXGateway.Dispatcher
  alias BullXGateway.ScopeWorker

  @type replay_response :: %{status: :replayed, dispatch: map()}

  def start_link(opts) do
    partition = Keyword.fetch!(opts, :partition)
    GenServer.start_link(__MODULE__, opts, name: via(partition))
  end

  @doc """
  Replay a dead-letter. Routes to the worker partition chosen by hashing
  `dispatch_id`.
  """
  @spec replay(String.t(), timeout()) ::
          {:ok, replay_response()} | {:error, :not_found | term()}
  def replay(dispatch_id, timeout \\ 30_000) when is_binary(dispatch_id) do
    partition = ReplaySupervisor.partition_for(dispatch_id)

    case whereis(partition) do
      nil -> {:error, :replay_unavailable}
      pid -> GenServer.call(pid, {:replay, dispatch_id}, timeout)
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{partition: Keyword.fetch!(opts, :partition)}}
  end

  @impl true
  def handle_call({:replay, dispatch_id}, _from, state) do
    reply = do_replay(dispatch_id)
    {:reply, reply, state}
  end

  defp do_replay(dispatch_id) do
    with {:ok, dead_letter} <- fetch_dead_letter(dispatch_id),
         {:ok, dispatch_row} <- enqueue_replay(dead_letter) do
      channel = {
        String.to_existing_atom(dead_letter.channel_adapter),
        dead_letter.channel_tenant
      }

      # Start (or look up) the ScopeWorker and enqueue the delivery id. This
      # is deliberately a cast; the caller observes replay progress via the
      # outcome signal on `BullXGateway.SignalBus` (see §7.8.1).
      case Dispatcher.ensure_started(channel, dead_letter.scope_id) do
        {:ok, _pid} ->
          ScopeWorker.enqueue(channel, dead_letter.scope_id, dispatch_id)
          {:ok, %{status: :replayed, dispatch: dispatch_row}}

        {:error, reason} ->
          Logger.error(
            "BullXGateway.DLQ.ReplayWorker failed to start ScopeWorker for #{dispatch_id}: #{inspect(reason)}"
          )

          {:error, {:scope_worker_start_failed, reason}}
      end
    end
  end

  defp fetch_dead_letter(dispatch_id) do
    case ControlPlane.fetch_dead_letter(dispatch_id) do
      {:ok, dead_letter} -> {:ok, dead_letter}
      :error -> {:error, :not_found}
    end
  end

  # Re-insert into gateway_dispatches with `attempts = attempts_total`
  # (continuation, not reset) and increment `replay_count` on the dead-letter
  # row. Both inside one transaction so either both happen or neither.
  defp enqueue_replay(dead_letter) do
    now = DateTime.utc_now()

    dispatch_attrs = %{
      id: dead_letter.dispatch_id,
      op: dead_letter.op,
      channel_adapter: dead_letter.channel_adapter,
      channel_tenant: dead_letter.channel_tenant,
      scope_id: dead_letter.scope_id,
      thread_id: dead_letter.thread_id,
      caused_by_signal_id: dead_letter.caused_by_signal_id,
      payload: dead_letter.payload,
      status: "queued",
      attempts: dead_letter.attempts_total,
      max_attempts: max(dead_letter.attempts_total + 1, default_max_attempts()),
      available_at: now,
      last_error: nil
    }

    case ControlPlane.transaction(fn store ->
           with :ok <- store.put_dispatch(dispatch_attrs),
                :ok <- store.increment_dead_letter_replay_count(dead_letter.dispatch_id) do
             {:ok, dispatch_attrs}
           end
         end) do
      {:ok, {:ok, attrs}} -> {:ok, attrs}
      {:error, :duplicate} -> {:error, :already_replaying}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_max_attempts do
    BullXGateway.RetryPolicy.default().max_attempts
  end

  defp via(partition) do
    {:via, Registry, {ReplaySupervisor.registry_name(), {:replay_worker, partition}}}
  end

  defp whereis(partition) do
    case Registry.lookup(ReplaySupervisor.registry_name(), {:replay_worker, partition}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
