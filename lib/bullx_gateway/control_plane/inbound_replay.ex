defmodule BullXGateway.ControlPlane.InboundReplay do
  @moduledoc false
  use GenServer

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.Deduper
  alias BullXGateway.Telemetry
  alias Jido.Signal
  alias Jido.Signal.Bus

  @default_interval_ms 60_000
  @default_grace_ms 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run_once do
    GenServer.call(__MODULE__, :run_once, :infinity)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms)
    }

    Process.send_after(self(), :bootstrap_replay, 0)
    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:run_once, _from, state) do
    {:reply, :ok, replay_pending(state, grace?: false)}
  end

  @impl true
  def handle_info(:bootstrap_replay, state) do
    {:noreply, replay_pending(state, grace?: false)}
  end

  def handle_info(:scheduled_replay, state) do
    schedule(state.interval_ms)
    {:noreply, replay_pending(state, grace?: true)}
  end

  defp replay_pending(state, opts) do
    records = list_pending_records(state, opts)

    {published, failed} =
      Enum.reduce(records, {0, 0}, fn record, {published, failed} ->
        case replay_record(record) do
          :ok -> {published + 1, failed}
          {:error, _} -> {published, failed + 1}
        end
      end)

    Telemetry.emit([:bullx, :gateway, :inbound_replay, :sweep], %{count: length(records)}, %{
      published: published,
      failed: failed
    })

    state
  end

  defp list_pending_records(state, opts) do
    filters =
      case Keyword.get(opts, :grace?, true) do
        true ->
          inserted_before = DateTime.add(DateTime.utc_now(), -state.grace_ms, :millisecond)
          [published: :pending, inserted_before: inserted_before]

        false ->
          [published: :pending]
      end

    case ControlPlane.list_trigger_records(filters) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp replay_record(record) do
    with {:ok, signal} <- Signal.from_map(record.signal_envelope),
         {:ok, _} <- Bus.publish(BullXGateway.SignalBus, [signal]),
         :ok <- ControlPlane.update_trigger_record(record.id, %{published_at: DateTime.utc_now()}),
         :ok <- Deduper.mark_seen(record.source, record.external_id, ttl_ms_for(record)) do
      :ok
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp ttl_ms_for(%{channel_adapter: adapter, channel_tenant: tenant}) do
    AdapterRegistry.dedupe_ttl_ms({adapter, tenant})
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :scheduled_replay, interval_ms)
  end
end
