defmodule BullX.Runtime.Targets.Writer do
  @moduledoc """
  The only supported write path for Runtime target and inbound route rows.

  It validates kind-specific target config before persistence and refreshes the
  in-memory route cache after successful writes.
  """

  alias BullX.Repo
  alias BullX.Runtime.Targets.Cache
  alias BullX.Runtime.Targets.Executor
  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Target
  alias BullXAIAgent.LLM.Catalog

  @aliases %{
    "default" => :default,
    "fast" => :fast,
    "heavy" => :heavy,
    "compression" => :compression
  }

  @target_keys ~w(key kind name description config)a
  @route_keys ~w(key name priority signal_pattern adapter channel_id scope_id thread_id actor_id event_type event_name event_name_prefix target_key)a
  @known_keys Map.new(@target_keys ++ @route_keys, &{Atom.to_string(&1), &1})
  @agentic_config_keys ~w(model system_prompt agentic_chat_loop)
  @system_prompt_keys ~w(soul)
  @agentic_loop_keys ~w(max_iterations max_tokens)

  @spec put_target(map()) :: {:ok, Target.t()} | {:error, term()}
  def put_target(attrs) when is_map(attrs) do
    with {:ok, attrs} <- prepare_target_attrs(attrs),
         {:ok, target} <- upsert_target(attrs) do
      Cache.refresh_all()
      {:ok, target}
    end
  end

  @spec update_target(Target.t(), map()) :: {:ok, Target.t()} | {:error, term()}
  def update_target(%Target{} = target, attrs) when is_map(attrs) do
    attrs =
      target |> Map.from_struct() |> Map.take(@target_keys) |> Map.merge(normalize_keys(attrs))

    with {:ok, attrs} <- prepare_target_attrs(attrs),
         {:ok, target} <- target |> Target.changeset(attrs) |> Repo.update() do
      Cache.refresh_all()
      {:ok, target}
    end
  end

  @spec delete_target(String.t()) :: :ok | {:error, term()}
  def delete_target(key) when is_binary(key) do
    case Repo.get(Target, key) do
      nil ->
        :ok

      %Target{} = target ->
        target
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:key,
          name: :runtime_inbound_routes_target_key_fkey
        )
        |> Repo.delete()
        |> case do
          {:ok, _target} ->
            Cache.refresh_all()
            :ok

          {:error, _changeset} = error ->
            error
        end
    end
  end

  @spec put_inbound_route(map()) :: {:ok, InboundRoute.t()} | {:error, term()}
  def put_inbound_route(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.take(@route_keys)
      |> normalize_route_defaults()

    with :ok <- validate_route_target(attrs),
         {:ok, route} <- upsert_inbound_route(attrs),
         :ok <- Cache.refresh_all() do
      {:ok, route}
    end
  end

  @spec update_inbound_route(InboundRoute.t(), map()) ::
          {:ok, InboundRoute.t()} | {:error, term()}
  def update_inbound_route(%InboundRoute{} = route, attrs) when is_map(attrs) do
    attrs =
      route
      |> Map.from_struct()
      |> Map.take(@route_keys)
      |> Map.merge(normalize_keys(attrs))
      |> normalize_route_defaults()

    with :ok <- validate_route_target(attrs),
         {:ok, route} <- route |> InboundRoute.changeset(attrs) |> Repo.update(),
         :ok <- Cache.refresh_all() do
      {:ok, route}
    end
  end

  @spec delete_inbound_route(String.t()) :: :ok | {:error, term()}
  def delete_inbound_route(key) when is_binary(key) do
    case Repo.get(InboundRoute, key) do
      nil ->
        :ok

      %InboundRoute{} = route ->
        case Repo.delete(route) do
          {:ok, _route} ->
            Cache.refresh_all()
            :ok

          {:error, _changeset} = error ->
            error
        end
    end
  end

  defp prepare_target_attrs(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.take(@target_keys)

    with {:ok, kind} <- fetch_string(attrs, :kind),
         :ok <- validate_supported_kind(kind),
         :ok <- validate_main_kind(attrs),
         {:ok, config} <- normalize_config(kind, Map.get(attrs, :config, %{})) do
      {:ok, Map.put(attrs, :config, config)}
    end
  end

  defp upsert_target(%{key: key} = attrs) when is_binary(key) do
    case Repo.get(Target, key) do
      nil -> %Target{} |> Target.changeset(attrs) |> Repo.insert()
      %Target{} = target -> target |> Target.changeset(attrs) |> Repo.update()
    end
  end

  defp upsert_target(_attrs), do: {:error, :missing_target_key}

  defp upsert_inbound_route(%{key: key} = attrs) when is_binary(key) do
    case Repo.get(InboundRoute, key) do
      nil -> %InboundRoute{} |> InboundRoute.changeset(attrs) |> Repo.insert()
      %InboundRoute{} = route -> route |> InboundRoute.changeset(attrs) |> Repo.update()
    end
  end

  defp upsert_inbound_route(_attrs), do: {:error, :missing_route_key}

  defp validate_supported_kind(kind) do
    case kind in Executor.supported_kinds() do
      true -> :ok
      false -> {:error, {:unsupported_target_kind, kind}}
    end
  end

  defp validate_main_kind(%{key: "main", kind: "agentic_chat_loop"}), do: :ok
  defp validate_main_kind(%{key: "main", kind: kind}), do: {:error, {:invalid_main_kind, kind}}
  defp validate_main_kind(_attrs), do: :ok

  defp normalize_config("agentic_chat_loop", config) do
    config = stringify_keys(config)

    with :ok <- validate_known_keys(config, @agentic_config_keys, :config),
         {:ok, model} <- fetch_required_trimmed(config, "model"),
         :ok <- validate_model(model),
         {:ok, system_prompt} <- normalize_system_prompt(config["system_prompt"]),
         {:ok, loop_config} <- normalize_agentic_loop_config(config["agentic_chat_loop"]) do
      {:ok,
       %{
         "model" => model,
         "system_prompt" => system_prompt,
         "agentic_chat_loop" => loop_config
       }}
    end
  end

  defp normalize_config("blackhole", config) do
    case stringify_keys(config) do
      %{} = empty when map_size(empty) == 0 -> {:ok, %{}}
      _ -> {:error, {:invalid_target_config, :blackhole_requires_empty_config}}
    end
  end

  defp normalize_config(kind, _config), do: {:error, {:unsupported_target_kind, kind}}

  defp normalize_system_prompt(prompt) do
    prompt = stringify_keys(prompt)

    with %{} <- prompt,
         :ok <- validate_known_keys(prompt, @system_prompt_keys, :system_prompt),
         {:ok, soul} <- fetch_required_trimmed(prompt, "soul") do
      {:ok, %{"soul" => soul}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_target_config, :system_prompt}}
    end
  end

  defp normalize_agentic_loop_config(nil) do
    {:ok, %{"max_iterations" => 4, "max_tokens" => 4_096}}
  end

  defp normalize_agentic_loop_config(config) do
    config = stringify_keys(config)

    with %{} <- config,
         :ok <- validate_known_keys(config, @agentic_loop_keys, :agentic_chat_loop),
         {:ok, max_iterations} <- positive_integer(config, "max_iterations", 4),
         {:ok, max_tokens} <- positive_integer(config, "max_tokens", 4_096) do
      {:ok, %{"max_iterations" => max_iterations, "max_tokens" => max_tokens}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_target_config, :agentic_chat_loop}}
    end
  end

  defp positive_integer(config, key, default) do
    case Map.get(config, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp validate_model(model) when is_map_key(@aliases, model), do: :ok

  defp validate_model(model) when is_binary(model) do
    case Catalog.find_provider(model) do
      {:ok, _provider} -> :ok
      {:error, :not_found} -> {:error, {:unknown_model, model}}
    end
  end

  defp validate_route_target(%{target_key: target_key}) when is_binary(target_key) do
    case Repo.get(Target, target_key) do
      %Target{} -> :ok
      nil -> {:error, {:unknown_target, target_key}}
    end
  end

  defp validate_route_target(_attrs), do: {:error, :missing_target_key}

  defp normalize_route_defaults(attrs) do
    attrs
    |> Map.put_new(:priority, 0)
    |> Map.put_new(:signal_pattern, "com.agentbull.x.inbound.**")
  end

  defp validate_known_keys(config, allowed, path) do
    unknown = Map.keys(config) -- allowed

    case unknown do
      [] -> :ok
      keys -> {:error, {:unknown_config_keys, path, Enum.sort(keys)}}
    end
  end

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_string, key}}
    end
  end

  defp fetch_required_trimmed(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:blank_required_string, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_required_string, key}}
    end
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {Map.get(@known_keys, key, key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} when is_binary(key) -> {key, stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(value), do: value
end
