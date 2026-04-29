defmodule BullX.Runtime.Targets.SessionRegistry do
  @moduledoc false

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec via_tuple(term()) :: {:via, Registry, {module(), term()}}
  def via_tuple(key), do: {:via, Registry, {__MODULE__, key}}

  @spec lookup(term()) :: {:ok, pid()} | :error
  def lookup(key) do
    case Registry.lookup(__MODULE__, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
