defmodule BullXGateway.Dispatcher do
  @moduledoc """
  DynamicSupervisor for `ScopeWorker` processes, keyed by `{channel, scope_id}`.

  Workers are started lazily on the first `deliver/1` for a scope. All state is
  in memory; on a BEAM crash the queues are lost and Runtime+Oban re-dispatches
  any outstanding work.
  """

  use DynamicSupervisor

  alias BullXGateway.ScopeRegistry
  alias BullXGateway.ScopeWorker

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Return the pid of the worker for `{channel, scope_id}`, starting one if
  none exists.
  """
  @spec ensure_started(BullXGateway.Delivery.channel(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(channel, scope_id, opts \\ []) do
    case ScopeRegistry.whereis(channel, scope_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_worker(channel, scope_id, opts)
    end
  end

  defp start_worker(channel, scope_id, opts) do
    spec = ScopeWorker.child_spec({channel, scope_id, opts})

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, _} = error ->
        case ScopeRegistry.whereis(channel, scope_id) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> error
        end
    end
  end

  @doc false
  def task_supervisor_name, do: BullXGateway.Dispatcher.TaskSupervisor
end
