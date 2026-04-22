defmodule BullXGateway.DLQ.ReplayWorker do
  @moduledoc """
  Serializes DLQ replay operations for one partition.

  Replay rebuilds a `BullXGateway.Delivery` from the dead-letter row and casts
  the living `ScopeWorker` for the `{channel, scope_id}`. The dead-letter row
  is preserved; `replay_count` is incremented on entry. The caller observes
  progress via the `delivery.*` outcome signal on `BullXGateway.SignalBus`.
  """

  use GenServer

  require Logger

  alias BullXGateway.ControlPlane
  alias BullXGateway.Delivery
  alias BullXGateway.DLQ.ReplaySupervisor
  alias BullXGateway.ScopeWorker

  @type replay_response :: %{status: :replayed, delivery: Delivery.t()}

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
         :ok <- ControlPlane.increment_dead_letter_replay_count(dispatch_id) do
      delivery = ScopeWorker.decode_delivery_from_dead_letter(dead_letter)

      case ScopeWorker.enqueue(delivery.channel, delivery.scope_id, delivery) do
        :ok ->
          {:ok, %{status: :replayed, delivery: delivery}}

        {:error, reason} ->
          Logger.error(
            "BullXGateway.DLQ.ReplayWorker failed to enqueue replay for #{dispatch_id}: #{inspect(reason)}"
          )

          {:error, {:scope_worker_enqueue_failed, reason}}
      end
    end
  end

  defp fetch_dead_letter(dispatch_id) do
    case ControlPlane.fetch_dead_letter(dispatch_id) do
      {:ok, dead_letter} -> {:ok, dead_letter}
      :error -> {:error, :not_found}
    end
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
