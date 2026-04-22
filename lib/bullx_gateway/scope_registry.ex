defmodule BullXGateway.ScopeRegistry do
  @moduledoc """
  Registry that names each `ScopeWorker` by its `{channel, scope_id}` key.

  Thin wrapper over `Registry` with via-tuple helpers so call sites don't have
  to repeat the registry module name or the partition tuple shape.
  """

  @type channel :: BullXGateway.Delivery.channel()

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Build a `:via` tuple for use with `GenServer.start_link(name: ...)` and
  `GenServer.call/cast` call sites.
  """
  @spec via(channel(), String.t()) :: {:via, Registry, {module(), term()}}
  def via(channel, scope_id) do
    {:via, Registry, {__MODULE__, {channel, scope_id}}}
  end

  @doc """
  Look up a running worker pid.
  """
  @spec whereis(channel(), String.t()) :: pid() | nil
  def whereis(channel, scope_id) do
    case Registry.lookup(__MODULE__, {channel, scope_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  List all known `{channel, scope_id}` keys currently registered.
  """
  @spec keys() :: [{channel(), String.t()}]
  def keys do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
