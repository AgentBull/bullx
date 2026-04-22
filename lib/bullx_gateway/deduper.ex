defmodule BullXGateway.Deduper do
  @moduledoc false
  use GenServer

  alias BullXGateway.ControlPlane
  alias BullXGateway.DedupeKey

  @table __MODULE__
  @default_sweep_interval_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def table_name, do: @table

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  def seen?(source, external_id) do
    dedupe_key = DedupeKey.generate(source, external_id)
    lookup_cache(dedupe_key) || lookup_store(dedupe_key)
  end

  def mark_seen(source, external_id, ttl_ms) when is_integer(ttl_ms) and ttl_ms >= 0 do
    GenServer.call(__MODULE__, {:mark_seen, source, external_id, ttl_ms})
  end

  @impl true
  def init(opts) do
    _table =
      :ets.new(@table, [
        :named_table,
        :set,
        :protected,
        read_concurrency: true,
        write_concurrency: true
      ])

    case ControlPlane.list_active_dedupe_seen() do
      {:ok, entries} -> Enum.each(entries, &cache_from_record/1)
      _ -> :ok
    end

    schedule_sweep(Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms))
    {:ok, %{sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:mark_seen, source, external_id, ttl_ms}, _from, state) do
    dedupe_key = DedupeKey.generate(source, external_id)
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl_ms, :millisecond)

    attrs = %{
      dedupe_key: dedupe_key,
      source: source,
      external_id: external_id,
      expires_at: expires_at,
      seen_at: now
    }

    reply =
      case ControlPlane.put_dedupe_seen(attrs) do
        :ok ->
          cache_put(dedupe_key, expires_at)
          :ok

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, %{sweep_interval_ms: sweep_interval_ms} = state) do
    sweep_cache()
    _ = ControlPlane.delete_expired_dedupe_seen()
    schedule_sweep(sweep_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:cache_seen, dedupe_key, expires_at}, state) do
    cache_put(dedupe_key, expires_at)
    {:noreply, state}
  end

  defp lookup_cache(dedupe_key) do
    now_ms = System.system_time(:millisecond)

    case :ets.lookup(@table, dedupe_key) do
      [{^dedupe_key, expires_at_ms}] when expires_at_ms > now_ms ->
        true

      [{^dedupe_key, _expires_at_ms}] ->
        :ets.delete(@table, dedupe_key)
        false

      [] ->
        false
    end
  end

  defp lookup_store(dedupe_key) do
    case ControlPlane.fetch_dedupe_seen(dedupe_key) do
      {:ok, %{expires_at: %DateTime{} = expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          GenServer.cast(__MODULE__, {:cache_seen, dedupe_key, expires_at})
          true
        else
          false
        end

      _ ->
        false
    end
  end

  defp cache_from_record(%{dedupe_key: dedupe_key, expires_at: %DateTime{} = expires_at}) do
    cache_put(dedupe_key, expires_at)
  end

  defp cache_put(dedupe_key, %DateTime{} = expires_at) do
    :ets.insert(@table, {dedupe_key, DateTime.to_unix(expires_at, :millisecond)})
  end

  defp sweep_cache do
    now_ms = System.system_time(:millisecond)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {dedupe_key, expires_at_ms} when expires_at_ms <= now_ms ->
        :ets.delete(@table, dedupe_key)

      _ ->
        :ok
    end)
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end
