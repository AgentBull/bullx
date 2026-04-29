defmodule BullX.Runtime.Targets.Ingress do
  @moduledoc false

  use GenServer

  alias BullX.Runtime.Targets
  alias Jido.Signal
  alias Jido.Signal.Bus

  require Logger

  @pattern "com.agentbull.x.inbound.**"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :bus, BullXGateway.SignalBus)

    case Bus.subscribe(bus, @pattern, dispatch: {:pid, target: self()}) do
      {:ok, subscription_id} -> {:ok, %{bus: bus, subscription_id: subscription_id}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    case dispatch_signal(signal) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("runtime target dispatch failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{bus: bus, subscription_id: subscription_id}) do
    Bus.unsubscribe(bus, subscription_id)
    :ok
  end

  defp dispatch_signal(%Signal{} = signal) do
    Targets.dispatch(signal)
  catch
    :exit, reason -> {:error, {:dispatch_exit, reason}}
  end
end
