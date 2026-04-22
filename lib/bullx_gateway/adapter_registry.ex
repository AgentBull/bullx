defmodule BullXGateway.AdapterRegistry do
  @moduledoc false
  use GenServer

  @default_dedupe_ttl_ms 86_400_000

  @type channel :: BullXGateway.Delivery.channel()
  @type entry :: %{
          module: module(),
          config: map()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def register(channel, module, config \\ %{}) when is_map(config) do
    GenServer.call(__MODULE__, {:register, channel, module, config})
  end

  def lookup(channel) do
    GenServer.call(__MODULE__, {:lookup, channel})
  end

  def dedupe_ttl_ms({adapter, tenant}) do
    case lookup({adapter, tenant}) do
      {:ok, %{config: %{dedupe_ttl_ms: ttl_ms}}} when is_integer(ttl_ms) and ttl_ms >= 0 ->
        ttl_ms

      _ ->
        @default_dedupe_ttl_ms
    end
  end

  @impl true
  def init(:ok) do
    {:ok, load_configured_adapters()}
  end

  @impl true
  def handle_call({:register, channel, module, config}, _from, state) do
    entry = %{module: module, config: config}
    {:reply, :ok, Map.put(state, normalize_channel(channel), entry)}
  end

  def handle_call({:lookup, channel}, _from, state) do
    {:reply, lookup_entry(state, normalize_channel(channel)), state}
  end

  defp load_configured_adapters do
    :bullx
    |> Application.get_env(BullXGateway, [])
    |> Keyword.get(:adapters, [])
    |> Enum.reduce(%{}, fn
      {channel, module, config}, acc when is_map(config) ->
        Map.put(acc, normalize_channel(channel), %{module: module, config: config})

      _, acc ->
        acc
    end)
  end

  defp normalize_channel({adapter, tenant}) when is_atom(adapter) and is_binary(tenant) do
    {adapter, tenant}
  end

  defp normalize_channel({adapter, tenant}) when is_binary(adapter) and is_binary(tenant) do
    {adapter, tenant}
  end

  defp normalize_channel(channel), do: channel

  defp lookup_entry(state, {adapter, tenant}) when is_binary(adapter) and is_binary(tenant) do
    entry =
      Enum.find_value(state, fn
        {{registered_adapter, ^tenant}, value} when is_atom(registered_adapter) ->
          if Atom.to_string(registered_adapter) == adapter, do: value

        {{^adapter, ^tenant}, value} ->
          value

        _ ->
          nil
      end)

    if entry, do: {:ok, entry}, else: :error
  end

  defp lookup_entry(state, channel), do: Map.fetch(state, channel)
end
