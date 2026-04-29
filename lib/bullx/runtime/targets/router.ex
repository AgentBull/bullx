defmodule BullX.Runtime.Targets.Router do
  @moduledoc false

  alias BullX.Runtime.Targets.Cache
  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Target
  alias Jido.Signal
  alias Jido.Signal.Router, as: JidoRouter

  @match_fields [
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :actor_id,
    :event_type,
    :event_name,
    :event_name_prefix
  ]

  @spec empty() :: JidoRouter.Router.t()
  def empty do
    JidoRouter.new!([])
  end

  @spec compile([InboundRoute.t()]) :: {:ok, JidoRouter.Router.t()} | {:error, term()}
  def compile(routes) when is_list(routes) do
    routes
    |> Enum.map(&route_spec/1)
    |> JidoRouter.new()
  end

  @spec resolve(Signal.t()) :: {:ok, map()} | {:error, term()}
  def resolve(%Signal{} = signal), do: resolve(signal, Cache.snapshot())

  @spec resolve(Signal.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve(%Signal{} = signal, %{router: router, routes: routes, targets: targets}) do
    result =
      case JidoRouter.route(router, signal) do
        {:ok, selected} ->
          selected
          |> candidates(routes, targets)
          |> select_candidate(signal, selected)

        {:error, _reason} ->
          {:ok, fallback_resolution(targets)}
      end

    emit_route_resolved(result, signal)
    result
  end

  @spec match_route?(InboundRoute.t(), Signal.t()) :: boolean()
  def match_route?(%InboundRoute{} = route, %Signal{} = signal) do
    exact_match?(route.adapter, extension(signal, "bullx_channel_adapter")) and
      exact_match?(route.channel_id, extension(signal, "bullx_channel_id")) and
      exact_match?(route.scope_id, data(signal, "scope_id")) and
      exact_match?(route.thread_id, data(signal, "thread_id")) and
      exact_match?(route.actor_id, data(signal, ["actor", "id"])) and
      exact_match?(route.event_type, data(signal, ["event", "type"])) and
      exact_match?(route.event_name, data(signal, ["event", "name"])) and
      prefix_match?(route.event_name_prefix, data(signal, ["event", "name"]))
  end

  defp route_spec(%InboundRoute{} = route) do
    {
      route.signal_pattern,
      fn signal -> match_route?(route, signal) end,
      {:runtime_target_route, route.key, route.target_key},
      route.priority
    }
  end

  defp candidates(selected, routes, targets) do
    Enum.flat_map(selected, fn
      {:runtime_target_route, route_key, target_key} ->
        with %InboundRoute{} = route <- Map.get(routes, route_key),
             %Target{} = target <- Map.get(targets, target_key) do
          [%{source: :db_route, route: route, target: target}]
        else
          _ -> []
        end

      _other ->
        []
    end)
  end

  defp select_candidate([], _signal, []), do: {:ok, fallback_resolution(%{})}

  defp select_candidate([], _signal, _selected),
    do: {:error, {:runtime_route_target_missing, :matched_route_without_target}}

  defp select_candidate(candidates, _signal, _selected) do
    selected =
      Enum.min_by(candidates, fn %{route: route} ->
        {-route.priority, -specificity(route), route.key}
      end)

    {:ok, selected}
  end

  defp fallback_resolution(targets) do
    %{
      source: :fallback,
      route: :main,
      target: Map.get(targets, "main", Target.default_main())
    }
  end

  defp emit_route_resolved(
         {:ok, %{target: %Target{} = target, route: route, source: source}},
         %Signal{} = signal
       ) do
    :telemetry.execute(
      [:bullx, :runtime, :targets, :route_resolved],
      %{count: 1},
      %{
        source: source,
        target_key: target.key,
        target_kind: target.kind,
        route_key: route_key(route),
        adapter: extension(signal, "bullx_channel_adapter"),
        channel_id: extension(signal, "bullx_channel_id"),
        scope_id: data(signal, "scope_id"),
        thread_id: data(signal, "thread_id"),
        signal_id: signal.id
      }
    )
  end

  defp emit_route_resolved(_result, _signal), do: :ok

  defp route_key(%{key: key}), do: key
  defp route_key(:main), do: "main"

  defp specificity(%InboundRoute{} = route) do
    Enum.reduce(@match_fields, 0, fn
      :event_name, acc -> acc + field_specificity(route.event_name, 2)
      :event_name_prefix, acc -> acc + field_specificity(route.event_name_prefix, 1)
      field, acc -> acc + field_specificity(Map.get(route, field), 1)
    end)
  end

  defp field_specificity(nil, _weight), do: 0
  defp field_specificity("", _weight), do: 0
  defp field_specificity(_value, weight), do: weight

  defp exact_match?(nil, _value), do: true
  defp exact_match?(expected, value), do: expected == value

  defp prefix_match?(nil, _value), do: true

  defp prefix_match?(prefix, value) when is_binary(prefix) and is_binary(value),
    do: String.starts_with?(value, prefix)

  defp prefix_match?(_prefix, _value), do: false

  defp extension(%Signal{extensions: extensions}, key) when is_map(extensions),
    do: Map.get(extensions, key)

  defp extension(_signal, _key), do: nil

  defp data(%Signal{data: data}, key) when is_map(data) and is_binary(key), do: Map.get(data, key)

  defp data(%Signal{data: data}, path) when is_map(data) and is_list(path),
    do: get_in(data, path)

  defp data(_signal, _key), do: nil
end
