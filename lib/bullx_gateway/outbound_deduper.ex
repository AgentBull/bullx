defmodule BullXGateway.OutboundDeduper do
  @moduledoc """
  ETS-backed cache of terminal-success outcomes, keyed by `delivery.id`.

  The cache is deliberately narrow: only `ScopeWorker` marks a success after a
  terminal adapter acknowledgement (RFC 0003 §7.7). Failures, in-flight
  dispatches, and retries never write here, so DLQ replays can never be
  misclassified as duplicates.
  """

  use GenServer

  alias BullXGateway.Delivery.Outcome

  @table __MODULE__
  @default_ttl_ms 5 * 60_000
  @default_sweep_interval_ms 60_000

  @type state :: %{
          table: :ets.tab(),
          ttl_ms: pos_integer(),
          sweep_interval_ms: pos_integer()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check whether a delivery id has a cached terminal-success outcome.

  Hot path — runs in the caller's process against the public ETS table.
  Returns `{:hit, %Outcome{}}` or `:miss`.
  """
  @spec seen?(String.t()) :: {:hit, Outcome.t()} | :miss
  def seen?(delivery_id) when is_binary(delivery_id) do
    now_ms = System.system_time(:millisecond)

    case :ets.lookup(@table, delivery_id) do
      [{^delivery_id, outcome, expires_at_ms}] when expires_at_ms > now_ms ->
        {:hit, outcome}

      [{^delivery_id, _outcome, _expires_at_ms}] ->
        :miss

      [] ->
        :miss
    end
  end

  @doc """
  Record a terminal success. Called only by `ScopeWorker` after a terminal
  success has been published.
  """
  @spec mark_success(String.t(), Outcome.t()) :: :ok
  def mark_success(delivery_id, %Outcome{} = outcome) when is_binary(delivery_id) do
    GenServer.cast(__MODULE__, {:mark_success, delivery_id, outcome})
  end

  @doc """
  Drop every cached entry. Test helper.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Run the sweep synchronously. Test helper.
  """
  @spec sweep() :: :ok
  def sweep do
    GenServer.call(__MODULE__, :sweep)
  end

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)

    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep(sweep_interval_ms)

    {:ok, %{table: @table, ttl_ms: ttl_ms, sweep_interval_ms: sweep_interval_ms}}
  end

  @impl true
  def handle_cast({:mark_success, delivery_id, outcome}, state) do
    expires_at_ms = System.system_time(:millisecond) + state.ttl_ms
    :ets.insert(state.table, {delivery_id, outcome, expires_at_ms})
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:sweep, _from, state) do
    sweep_expired(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired(state.table)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  defp sweep_expired(table) do
    now_ms = System.system_time(:millisecond)
    match_spec = [{{:"$1", :_, :"$2"}, [{:"=<", :"$2", now_ms}], [:"$1"]}]

    table
    |> :ets.select(match_spec)
    |> Enum.each(&:ets.delete(table, &1))
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end
