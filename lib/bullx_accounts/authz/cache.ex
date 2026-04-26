defmodule BullXAccounts.AuthZ.Cache do
  @moduledoc """
  Local ETS owner for AuthZ decision and computed-group caches.

  Cache entries are reconstructible. Process restart loses all entries; new
  authorization requests reload from PostgreSQL. The cache is invalidated
  coarsely on every group, membership, grant, or user-status write.
  """

  use GenServer

  alias BullX.Config.Accounts, as: AccountsConfig

  require Logger

  @decisions_table :bullx_authz_decisions
  @groups_table :bullx_authz_groups

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@decisions_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@groups_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Look up a cached decision. Returns `{:ok, :allow}`, `{:ok, :deny}`, or
  `:miss`. Expired entries are returned as `:miss`.
  """
  @spec fetch_decision(term()) :: {:ok, :allow | :deny} | :miss
  def fetch_decision(key) do
    if caching_enabled?() do
      now = monotonic_ms()

      try do
        case :ets.lookup(@decisions_table, key) do
          [{^key, decision, expires_at}] when expires_at > now -> {:ok, decision}
          [{^key, _decision, _expires_at}] -> :miss
          [] -> :miss
        end
      rescue
        exception in [ArgumentError] ->
          log_table_unavailable(:fetch_decision, exception)
          :miss
      end
    else
      :miss
    end
  end

  @doc "Store an allow/deny decision in the cache. No-op when caching is disabled."
  @spec put_decision(term(), :allow | :deny) :: :ok
  def put_decision(key, decision) when decision in [:allow, :deny] do
    case ttl_ms() do
      0 ->
        :ok

      ttl ->
        try do
          :ets.insert(@decisions_table, {key, decision, monotonic_ms() + ttl})
          :ok
        rescue
          exception in [ArgumentError] ->
            log_table_unavailable(:put_decision, exception)
            :ok
        end
    end
  end

  @doc """
  Look up cached effective group ids for a user. Returns
  `{:ok, {static_ids, computed_ids}}` or `:miss`.
  """
  @spec fetch_groups(Ecto.UUID.t()) ::
          {:ok, {[Ecto.UUID.t()], [Ecto.UUID.t()]}} | :miss
  def fetch_groups(user_id) do
    if caching_enabled?() do
      now = monotonic_ms()

      try do
        case :ets.lookup(@groups_table, user_id) do
          [{^user_id, value, expires_at}] when expires_at > now -> {:ok, value}
          [{^user_id, _value, _expires_at}] -> :miss
          [] -> :miss
        end
      rescue
        exception in [ArgumentError] ->
          log_table_unavailable(:fetch_groups, exception)
          :miss
      end
    else
      :miss
    end
  end

  @doc "Store effective group ids for a user. No-op when caching is disabled."
  @spec put_groups(Ecto.UUID.t(), {[Ecto.UUID.t()], [Ecto.UUID.t()]}) :: :ok
  def put_groups(user_id, value) do
    case ttl_ms() do
      0 ->
        :ok

      ttl ->
        try do
          :ets.insert(@groups_table, {user_id, value, monotonic_ms() + ttl})
          :ok
        rescue
          exception in [ArgumentError] ->
            log_table_unavailable(:put_groups, exception)
            :ok
        end
    end
  end

  @doc """
  Invalidate all cached decisions and group expansions.

  Called by every public AuthZ write path so callers see the new state on
  the next authorize call.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    try do
      :ets.delete_all_objects(@decisions_table)
      :ets.delete_all_objects(@groups_table)
      :ok
    rescue
      exception in [ArgumentError] ->
        log_table_unavailable(:invalidate_all, exception)
        :ok
    end
  end

  defp caching_enabled?, do: ttl_ms() > 0

  defp ttl_ms do
    case AccountsConfig.accounts_authz_cache_ttl_ms() do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp log_table_unavailable(operation, exception) do
    Logger.warning(
      "BullXAccounts.AuthZ.Cache: ETS operation #{operation} degraded: #{Exception.message(exception)}"
    )
  end
end
