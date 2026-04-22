defmodule BullXGateway.DLQ.ReplaySupervisor do
  @moduledoc """
  Bounds DLQ replay concurrency by partitioning replay requests across N
  `ReplayWorker` GenServers. Requests for a given `dispatch_id` always route
  to the same worker via `:erlang.phash2({:replay, dispatch_id}, N)`, so the
  same dispatch cannot be replayed twice in parallel.
  """

  use Supervisor

  alias BullXGateway.DLQ.ReplayWorker

  @registry BullXGateway.DLQ.ReplayRegistry
  @default_partitions 4

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    partitions = Keyword.get(opts, :partitions, @default_partitions)
    :persistent_term.put({__MODULE__, :partitions}, partitions)

    workers =
      for index <- 0..(partitions - 1) do
        Supervisor.child_spec({ReplayWorker, partition: index}, id: {ReplayWorker, index})
      end

    children = [{Registry, keys: :unique, name: @registry} | workers]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The module used as the Registry name for `ReplayWorker` via-tuples.
  """
  @spec registry_name() :: module()
  def registry_name, do: @registry

  @doc """
  Return the partition index for `dispatch_id`.
  """
  @spec partition_for(String.t()) :: non_neg_integer()
  def partition_for(dispatch_id) when is_binary(dispatch_id) do
    :erlang.phash2({:replay, dispatch_id}, partitions())
  end

  @doc """
  Number of partitions configured at start time.
  """
  @spec partitions() :: pos_integer()
  def partitions do
    :persistent_term.get({__MODULE__, :partitions}, @default_partitions)
  end
end
