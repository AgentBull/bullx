defmodule BullX.Config.Cache do
  use GenServer
  require Logger

  @table :bullx_config_db

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reads a raw string value from ETS. Returns `:error` if absent or table unavailable."
  def get_raw(key) when is_binary(key) do
    try do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  @doc "Removes a key from ETS without touching the database. Used for test cleanup."
  def delete_raw(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:delete_raw, key})
  end

  @doc "Reloads a single key from PostgreSQL and updates ETS."
  def refresh(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:refresh, key})
  end

  @doc "Reloads all keys from PostgreSQL."
  def refresh_all do
    GenServer.call(__MODULE__, :refresh_all)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:delete_raw, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:refresh, key}, _from, state) do
    do_refresh_key(key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:refresh_all, _from, state) do
    load_all()
    {:reply, :ok, state}
  end

  defp load_all do
    try do
      rows = BullX.Repo.all(BullX.Config.AppConfig)
      :ets.delete_all_objects(@table)

      Enum.each(rows, fn %BullX.Config.AppConfig{key: key, value: value} ->
        :ets.insert(@table, {key, value})
      end)
    rescue
      e ->
        Logger.warning(
          "BullX.Config.Cache: failed to load from database, starting with empty cache: #{Exception.message(e)}"
        )
    end
  end

  defp do_refresh_key(key) do
    try do
      case BullX.Repo.get(BullX.Config.AppConfig, key) do
        nil -> :ets.delete(@table, key)
        %BullX.Config.AppConfig{value: value} -> :ets.insert(@table, {key, value})
      end
    rescue
      e ->
        Logger.warning(
          "BullX.Config.Cache: failed to refresh key #{inspect(key)}: #{Exception.message(e)}"
        )
    end
  end
end
