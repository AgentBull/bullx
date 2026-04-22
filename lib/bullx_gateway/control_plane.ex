defmodule BullXGateway.ControlPlane do
  @moduledoc false
  use GenServer

  alias BullXGateway.ControlPlane.Store.Postgres, as: PostgresStore
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

  # --- Outbound (RFC 0003) ---

  def put_dispatch(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put_dispatch, attrs}, :infinity)
  end

  def update_dispatch(id, changes) do
    GenServer.call(__MODULE__, {:update_dispatch, id, changes}, :infinity)
  end

  def delete_dispatch(id) do
    GenServer.call(__MODULE__, {:delete_dispatch, id}, :infinity)
  end

  def fetch_dispatch(id) do
    GenServer.call(__MODULE__, {:fetch_dispatch, id}, :infinity)
  end

  def list_dispatches_by_scope(channel, scope_id, statuses) do
    GenServer.call(
      __MODULE__,
      {:list_dispatches_by_scope, channel, scope_id, statuses},
      :infinity
    )
  end

  def put_attempt(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put_attempt, attrs}, :infinity)
  end

  def list_attempts(dispatch_id) do
    GenServer.call(__MODULE__, {:list_attempts, dispatch_id}, :infinity)
  end

  def put_dead_letter(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put_dead_letter, attrs}, :infinity)
  end

  def fetch_dead_letter(dispatch_id) do
    GenServer.call(__MODULE__, {:fetch_dead_letter, dispatch_id}, :infinity)
  end

  def list_dead_letters(filters \\ []) do
    GenServer.call(__MODULE__, {:list_dead_letters, filters}, :infinity)
  end

  def increment_dead_letter_replay_count(dispatch_id) do
    GenServer.call(__MODULE__, {:increment_dead_letter_replay_count, dispatch_id}, :infinity)
  end

  def archive_dead_letter(dispatch_id) do
    GenServer.call(__MODULE__, {:archive_dead_letter, dispatch_id}, :infinity)
  end

  def purge_dead_letter(dispatch_id) do
    GenServer.call(__MODULE__, {:purge_dead_letter, dispatch_id}, :infinity)
  end

  def delete_old_attempts(before) do
    GenServer.call(__MODULE__, {:delete_old_attempts, before}, :infinity)
  end

  def delete_old_dead_letters(before) do
    GenServer.call(__MODULE__, {:delete_old_dead_letters, before}, :infinity)
  end

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, PostgresStore)
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

  def handle_call({:put_dispatch, attrs}, _from, %{store: store} = state) do
    {:reply, store.put_dispatch(attrs), state}
  end

  def handle_call({:update_dispatch, id, changes}, _from, %{store: store} = state) do
    {:reply, store.update_dispatch(id, changes), state}
  end

  def handle_call({:delete_dispatch, id}, _from, %{store: store} = state) do
    {:reply, store.delete_dispatch(id), state}
  end

  def handle_call({:fetch_dispatch, id}, _from, %{store: store} = state) do
    {:reply, store.fetch_dispatch(id), state}
  end

  def handle_call(
        {:list_dispatches_by_scope, channel, scope_id, statuses},
        _from,
        %{store: store} = state
      ) do
    {:reply, store.list_dispatches_by_scope(channel, scope_id, statuses), state}
  end

  def handle_call({:put_attempt, attrs}, _from, %{store: store} = state) do
    {:reply, store.put_attempt(attrs), state}
  end

  def handle_call({:list_attempts, dispatch_id}, _from, %{store: store} = state) do
    {:reply, store.list_attempts(dispatch_id), state}
  end

  def handle_call({:put_dead_letter, attrs}, _from, %{store: store} = state) do
    {:reply, store.put_dead_letter(attrs), state}
  end

  def handle_call({:fetch_dead_letter, dispatch_id}, _from, %{store: store} = state) do
    {:reply, store.fetch_dead_letter(dispatch_id), state}
  end

  def handle_call({:list_dead_letters, filters}, _from, %{store: store} = state) do
    {:reply, store.list_dead_letters(filters), state}
  end

  def handle_call(
        {:increment_dead_letter_replay_count, dispatch_id},
        _from,
        %{store: store} = state
      ) do
    {:reply, store.increment_dead_letter_replay_count(dispatch_id), state}
  end

  def handle_call({:archive_dead_letter, dispatch_id}, _from, %{store: store} = state) do
    {:reply, invoke_optional(store, :archive_dead_letter, [dispatch_id]), state}
  end

  def handle_call({:purge_dead_letter, dispatch_id}, _from, %{store: store} = state) do
    {:reply, invoke_optional(store, :purge_dead_letter, [dispatch_id]), state}
  end

  def handle_call({:delete_old_attempts, before}, _from, %{store: store} = state) do
    {:reply, invoke_optional(store, :delete_old_attempts, [before]), state}
  end

  def handle_call({:delete_old_dead_letters, before}, _from, %{store: store} = state) do
    {:reply, invoke_optional(store, :delete_old_dead_letters, [before]), state}
  end

  defp invoke_optional(store, fun, args) do
    if function_exported?(store, fun, length(args)) do
      apply(store, fun, args)
    else
      {:error, :not_implemented}
    end
  end

  defp duration(started_at) do
    System.monotonic_time() - started_at
  end

  defp telemetry_result({:ok, _}), do: :ok
  defp telemetry_result(:ok), do: :ok
  defp telemetry_result(_), do: :error
end
