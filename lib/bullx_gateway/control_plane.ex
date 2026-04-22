defmodule BullXGateway.ControlPlane do
  @moduledoc false
  use GenServer

  alias BullXGateway.Telemetry

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def transaction(fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:transaction, fun}, :infinity)
  end

  def fetch_trigger_record_by_dedupe_key(dedupe_key) do
    GenServer.call(__MODULE__, {:fetch_trigger_record_by_dedupe_key, dedupe_key}, :infinity)
  end

  def list_trigger_records(filters \\ []) do
    GenServer.call(__MODULE__, {:list_trigger_records, filters}, :infinity)
  end

  def update_trigger_record(id, changes) do
    GenServer.call(__MODULE__, {:update_trigger_record, id, changes}, :infinity)
  end

  def put_dedupe_seen(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put_dedupe_seen, attrs}, :infinity)
  end

  def fetch_dedupe_seen(dedupe_key) do
    GenServer.call(__MODULE__, {:fetch_dedupe_seen, dedupe_key}, :infinity)
  end

  def list_active_dedupe_seen do
    GenServer.call(__MODULE__, :list_active_dedupe_seen, :infinity)
  end

  def delete_expired_dedupe_seen do
    GenServer.call(__MODULE__, :delete_expired_dedupe_seen, :infinity)
  end

  def delete_old_trigger_records(before) do
    GenServer.call(__MODULE__, {:delete_old_trigger_records, before}, :infinity)
  end

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, BullXGateway.ControlPlane.Store.Postgres)
    {:ok, %{store: store}}
  end

  @impl true
  def handle_call({:transaction, fun}, _from, %{store: store} = state) do
    started_at = System.monotonic_time()
    result = store.transaction(fun)

    Telemetry.emit([:bullx, :gateway, :store, :transaction], %{duration: duration(started_at)}, %{
      result: telemetry_result(result),
      store: store
    })

    {:reply, result, state}
  end

  def handle_call(
        {:fetch_trigger_record_by_dedupe_key, dedupe_key},
        _from,
        %{store: store} = state
      ) do
    {:reply, store.fetch_trigger_record_by_dedupe_key(dedupe_key), state}
  end

  def handle_call({:list_trigger_records, filters}, _from, %{store: store} = state) do
    {:reply, store.list_trigger_records(filters), state}
  end

  def handle_call({:update_trigger_record, id, changes}, _from, %{store: store} = state) do
    {:reply, store.update_trigger_record(id, changes), state}
  end

  def handle_call({:put_dedupe_seen, attrs}, _from, %{store: store} = state) do
    {:reply, store.put_dedupe_seen(attrs), state}
  end

  def handle_call({:fetch_dedupe_seen, dedupe_key}, _from, %{store: store} = state) do
    {:reply, store.fetch_dedupe_seen(dedupe_key), state}
  end

  def handle_call(:list_active_dedupe_seen, _from, %{store: store} = state) do
    {:reply, store.list_active_dedupe_seen(), state}
  end

  def handle_call(:delete_expired_dedupe_seen, _from, %{store: store} = state) do
    {:reply, store.delete_expired_dedupe_seen(), state}
  end

  def handle_call({:delete_old_trigger_records, before}, _from, %{store: store} = state) do
    {:reply, store.delete_old_trigger_records(before), state}
  end

  defp duration(started_at) do
    System.monotonic_time() - started_at
  end

  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result(:ok), do: :ok
  defp telemetry_result(_), do: :error
end
