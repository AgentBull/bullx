defmodule BullXGateway.ControlPlane do
  @moduledoc false
  use GenServer

  alias BullXGateway.ControlPlane.Store.Postgres, as: PostgresStore

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def transaction(fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:transaction, fun}, :infinity)
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

  def purge_dead_letter(dispatch_id) do
    GenServer.call(__MODULE__, {:purge_dead_letter, dispatch_id}, :infinity)
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
    {:reply, store.transaction(fun), state}
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

  def handle_call({:purge_dead_letter, dispatch_id}, _from, %{store: store} = state) do
    {:reply, invoke_optional(store, :purge_dead_letter, [dispatch_id]), state}
  end

  def handle_call({:delete_old_dead_letters, before}, _from, %{store: store} = state) do
    {:reply, store.delete_old_dead_letters(before), state}
  end

  defp invoke_optional(store, fun, args) do
    if function_exported?(store, fun, length(args)) do
      apply(store, fun, args)
    else
      {:error, :not_implemented}
    end
  end
end
