defmodule BullX.Runtime.Targets.Kind.Blackhole do
  @moduledoc false

  alias BullX.Runtime.Targets.Target
  alias Jido.Signal

  @spec run(map(), keyword()) :: {:ok, %{blackholed: true}}
  def run(%{target: %Target{} = target, route: route, signal: %Signal{} = signal}, _opts \\ []) do
    :telemetry.execute(
      [:bullx, :runtime, :targets, :target_blackholed],
      %{count: 1},
      metadata(target, route, signal)
    )

    {:ok, %{blackholed: true}}
  end

  defp metadata(%Target{} = target, route, %Signal{} = signal) do
    %{
      target_key: target.key,
      target_kind: target.kind,
      route_key: route_key(route),
      adapter: get_in(signal.extensions || %{}, ["bullx_channel_adapter"]),
      channel_id: get_in(signal.extensions || %{}, ["bullx_channel_id"]),
      scope_id: get_in(signal.data || %{}, ["scope_id"]),
      thread_id: get_in(signal.data || %{}, ["thread_id"]),
      signal_id: signal.id
    }
  end

  defp route_key(%{key: key}), do: key
  defp route_key(:main), do: "main"
end
