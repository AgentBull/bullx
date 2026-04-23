defmodule BullXGateway.AdapterSupervisor do
  @moduledoc false
  use Supervisor

  alias BullXGateway.AdapterRegistry

  @registry __MODULE__.Registry
  @dynamic_supervisor __MODULE__.DynamicSupervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Supervisor.start_link(__MODULE__, :ok, name: name) do
      {:ok, pid} ->
        case start_configured_channels(
               Keyword.get(opts, :adapters, BullX.Config.Gateway.adapters())
             ) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            Supervisor.stop(pid)
            {:error, reason}
        end

      other ->
        other
    end
  end

  def start_channel(channel, module, config \\ %{})

  def start_channel(channel, module, config) when is_atom(module) and is_map(config) do
    with :ok <- ensure_adapter_module(module),
         {:ok, pid} <- start_channel_supervisor(channel, module, config),
         :ok <- AdapterRegistry.register(channel, module, Map.put(config, :anchor_pid, pid)) do
      {:ok, pid}
    end
  end

  def start_channel(_channel, _module, _config), do: {:error, :invalid_adapter_spec}

  def stop_channel(channel) do
    case whereis_channel(channel) do
      pid when is_pid(pid) ->
        with :ok <- DynamicSupervisor.terminate_child(@dynamic_supervisor, pid),
             :ok <- AdapterRegistry.unregister(channel) do
          :ok
        end

      nil ->
        case AdapterRegistry.lookup(channel) do
          {:ok, _entry} -> AdapterRegistry.unregister(channel)
          :error -> {:error, :not_found}
        end
    end
  end

  def whereis_channel(channel) do
    case Registry.lookup(@registry, channel) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc false
  def channel_via(channel), do: {:via, Registry, {@registry, channel}}

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp start_channel_supervisor(channel, module, config) do
    case DynamicSupervisor.start_child(
           @dynamic_supervisor,
           {BullXGateway.AdapterSupervisor.Channel, {channel, module, config}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_adapter_module(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :adapter_id, 0),
         true <- function_exported?(module, :capabilities, 0) do
      :ok
    else
      _ -> {:error, {:invalid_adapter_module, module}}
    end
  end

  defp start_configured_channels(adapters) do
    Enum.reduce_while(adapters, :ok, fn
      {channel, module, config}, :ok when is_map(config) ->
        case start_channel(channel, module, config) do
          {:ok, _pid} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:adapter_start_failed, channel, reason}}}
        end

      _other, :ok ->
        {:cont, :ok}
    end)
  end
end

defmodule BullXGateway.AdapterSupervisor.Channel do
  @moduledoc false
  use Supervisor

  def child_spec({channel, module, config}) do
    %{
      id: {__MODULE__, channel},
      start: {__MODULE__, :start_link, [{channel, module, config}]},
      restart: :permanent,
      type: :supervisor
    }
  end

  def start_link({channel, module, config}) do
    Supervisor.start_link(__MODULE__, {channel, module, config},
      name: BullXGateway.AdapterSupervisor.channel_via(channel)
    )
  end

  @impl true
  def init({channel, module, config}) do
    children =
      if function_exported?(module, :child_specs, 2) do
        module.child_specs(channel, config)
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
