defmodule BullXGateway.Retention do
  @moduledoc false
  use GenServer

  alias BullXGateway.ControlPlane

  @default_interval_ms :timer.hours(1)
  @dead_letters_retention_seconds 90 * 24 * 60 * 60

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run_once do
    GenServer.cast(__MODULE__, :run_once)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_cast(:run_once, state) do
    {:noreply, run_cleanup(state)}
  end

  @impl true
  def handle_info(:cleanup, %{interval_ms: interval_ms} = state) do
    schedule(interval_ms)
    {:noreply, run_cleanup(state)}
  end

  defp run_cleanup(state) do
    now = DateTime.utc_now()

    _ = ControlPlane.delete_expired_dedupe_seen()

    _ =
      ControlPlane.delete_old_dead_letters(
        DateTime.add(now, -@dead_letters_retention_seconds, :second)
      )

    state
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
