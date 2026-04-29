defmodule BullXAIAgent.LLM.Writer do
  @moduledoc """
  Write API for LLM providers and alias bindings.

  This is the only supported persistence path for the LLM catalog. It encrypts
  API keys before insert/update and refreshes the read cache after each
  successful write.
  """

  import Ecto.Query

  alias BullX.Repo
  alias BullXAIAgent.LLM.AliasBinding
  alias BullXAIAgent.LLM.Catalog
  alias BullXAIAgent.LLM.Catalog.Cache
  alias BullXAIAgent.LLM.Crypto
  alias BullXAIAgent.LLM.Provider
  alias BullXAIAgent.LLM.ProviderOptions

  @aliases [:default, :fast, :heavy, :compression]

  @type provider_attrs :: %{
          required(:name) => String.t(),
          required(:provider_id) => String.t(),
          required(:model_id) => String.t(),
          optional(:base_url) => String.t(),
          optional(:api_key) => String.t() | nil,
          optional(:provider_options) => map()
        }

  @spec put_provider(provider_attrs()) :: {:ok, Provider.t()} | {:error, term()}
  def put_provider(attrs) when is_map(attrs) do
    id = BullX.Ext.gen_uuid_v7()

    with {:ok, prepared} <- prepare_provider_attrs(attrs, id, :insert),
         {:ok, provider} <-
           Repo.transaction(fn ->
             %Provider{id: id}
             |> Provider.changeset(prepared)
             |> Repo.insert()
           end)
           |> unwrap_transaction() do
      Cache.refresh_all()
      {:ok, provider}
    end
  end

  @spec update_provider(Provider.t(), provider_attrs()) :: {:ok, Provider.t()} | {:error, term()}
  def update_provider(%Provider{} = provider, attrs) when is_map(attrs) do
    with {:ok, prepared} <- prepare_provider_attrs(attrs, provider.id, :update),
         {:ok, provider} <-
           Repo.transaction(fn ->
             provider
             |> Provider.changeset(prepared)
             |> Repo.update()
           end)
           |> unwrap_transaction() do
      Cache.refresh_all()
      {:ok, provider}
    end
  end

  @spec delete_provider(String.t()) :: :ok | {:error, term()}
  def delete_provider(name) when is_binary(name) do
    case Repo.get_by(Provider, name: name) do
      nil ->
        {:error, :not_found}

      %Provider{} = provider ->
        do_delete_provider(provider)
    end
  end

  @spec put_alias_binding(
          Catalog.alias_name(),
          {:provider, String.t()} | {:alias, Catalog.alias_name()} | tuple()
        ) :: {:ok, AliasBinding.t()} | {:error, term()}
  def put_alias_binding(alias_name, {:provider, provider_name}) do
    with {:ok, alias_name} <- normalize_alias(alias_name),
         {:ok, %Provider{} = provider} <- fetch_provider(provider_name),
         :ok <- validate_alias_graph(alias_name, {:provider, provider.id}),
         {:ok, binding} <- upsert_alias_binding(alias_name, {:provider, provider}) do
      Cache.refresh_alias(alias_name)
      {:ok, binding}
    end
  end

  def put_alias_binding(alias_name, {:alias, target_alias}) do
    with {:ok, alias_name} <- normalize_alias(alias_name),
         {:ok, target_alias} <- normalize_alias(target_alias),
         :ok <- validate_alias_target(alias_name, target_alias),
         :ok <- validate_alias_graph(alias_name, {:alias, target_alias}),
         {:ok, binding} <- upsert_alias_binding(alias_name, {:alias, target_alias}) do
      Cache.refresh_alias(alias_name)
      {:ok, binding}
    end
  end

  def put_alias_binding(alias_name, target) when is_tuple(target) and tuple_size(target) == 2 do
    with {:ok, alias_name} <- normalize_alias(alias_name) do
      {:error, {:invalid_alias_binding, alias_name}}
    end
  end

  def put_alias_binding(alias_name, _target) do
    with {:ok, alias_name} <- normalize_alias(alias_name) do
      {:error, {:invalid_alias_binding, alias_name}}
    end
  end

  @spec delete_alias_binding(Catalog.alias_name()) :: :ok | {:error, term()}
  def delete_alias_binding(alias_name) do
    case normalize_alias(alias_name) do
      {:ok, alias_name} ->
        with :ok <- validate_alias_delete(alias_name) do
          Repo.delete_all(
            from(binding in AliasBinding,
              where: binding.alias_name == ^alias_to_string(alias_name)
            )
          )

          Cache.refresh_alias(alias_name)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp prepare_provider_attrs(attrs, provider_id, mode) do
    attrs = normalize_provider_keys(attrs)

    with {:ok, attrs} <- validate_req_llm_provider(attrs),
         {:ok, attrs} <- normalize_provider_options(attrs),
         {:ok, encrypted_api_key} <- encrypted_api_key(attrs, provider_id, mode) do
      {:ok,
       attrs
       |> Map.drop([:api_key])
       |> maybe_put_encrypted_api_key(encrypted_api_key, mode)}
    end
  end

  defp normalize_provider_options(%{provider_id: provider_id} = attrs) do
    provider_options =
      case Map.get(attrs, :provider_options) do
        options when is_map(options) -> options
        _other -> %{}
      end

    case ProviderOptions.normalize_for_storage(provider_id, provider_options) do
      {:ok, normalized} -> {:ok, Map.put(attrs, :provider_options, normalized)}
      {:error, reason} -> {:error, {:invalid_provider_options, reason}}
    end
  end

  defp normalize_provider_options(attrs), do: {:ok, Map.put(attrs, :provider_options, %{})}

  defp normalize_provider_keys(attrs) do
    Map.new(attrs, fn
      {"name", value} -> {:name, value}
      {"provider_id", value} -> {:provider_id, value}
      {"model_id", value} -> {:model_id, value}
      {"base_url", value} -> {:base_url, value}
      {"api_key", value} -> {:api_key, value}
      {"provider_options", value} -> {:provider_options, value}
      {key, value} -> {key, value}
    end)
  end

  defp validate_req_llm_provider(%{provider_id: provider_id, model_id: model_id} = attrs)
       when is_binary(provider_id) and is_binary(model_id) do
    case provider_atom(provider_id) do
      {:ok, provider} ->
        model =
          %{provider: provider, id: model_id} |> maybe_put_base_url(Map.get(attrs, :base_url))

        case ReqLLM.model(model) do
          {:ok, _model} -> {:ok, attrs}
          {:error, reason} -> {:error, {:invalid_model, reason}}
        end

      {:error, _reason} ->
        {:error, {:unknown_req_llm_provider, provider_id}}
    end
  end

  defp validate_req_llm_provider(attrs), do: {:ok, attrs}

  defp provider_atom(provider_id) do
    ReqLLM.Providers.list()
    |> Enum.find(&(Atom.to_string(&1) == provider_id))
    |> case do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  defp maybe_put_base_url(model, nil), do: model
  defp maybe_put_base_url(model, ""), do: model
  defp maybe_put_base_url(model, base_url), do: Map.put(model, :base_url, base_url)

  defp encrypted_api_key(attrs, _provider_id, :update) when not is_map_key(attrs, :api_key) do
    {:ok, :preserve}
  end

  defp encrypted_api_key(%{api_key: nil}, _provider_id, _mode), do: {:ok, nil}
  defp encrypted_api_key(%{api_key: ""}, _provider_id, _mode), do: {:ok, nil}

  defp encrypted_api_key(%{api_key: api_key}, provider_id, _mode) when is_binary(api_key) do
    api_key
    |> String.trim()
    |> case do
      "" -> {:ok, nil}
      value -> Crypto.encrypt_api_key(value, provider_id)
    end
  end

  defp encrypted_api_key(_attrs, _provider_id, :insert), do: {:ok, nil}

  defp maybe_put_encrypted_api_key(attrs, :preserve, :update), do: attrs

  defp maybe_put_encrypted_api_key(attrs, encrypted_api_key, _mode),
    do: Map.put(attrs, :encrypted_api_key, encrypted_api_key)

  defp do_delete_provider(%Provider{} = provider) do
    case referenced_alias(provider.id) do
      nil ->
        case Repo.transaction(fn -> Repo.delete(Provider.delete_changeset(provider)) end)
             |> unwrap_transaction() do
          {:ok, _provider} ->
            Cache.refresh_all()
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      alias_name ->
        {:error, {:still_referenced_by_alias, alias_name}}
    end
  end

  defp referenced_alias(provider_id) do
    Repo.one(
      from(binding in AliasBinding,
        where: binding.target_kind == "provider" and binding.target_provider_id == ^provider_id,
        select: binding.alias_name,
        limit: 1
      )
    )
    |> case do
      nil -> nil
      alias_name -> alias_to_atom(alias_name)
    end
  end

  defp fetch_provider(provider_name) when is_binary(provider_name) do
    case Repo.get_by(Provider, name: provider_name) do
      %Provider{} = provider -> {:ok, provider}
      nil -> {:error, {:unknown_provider, provider_name}}
    end
  end

  defp fetch_provider(provider_name), do: {:error, {:unknown_provider, provider_name}}

  defp validate_alias_target(:default, _target_alias),
    do: {:error, {:default_alias_must_target_provider, :default}}

  defp validate_alias_target(_alias_name, _target_alias), do: :ok

  defp validate_alias_graph(alias_name, target) do
    binding_map =
      AliasBinding
      |> Repo.all()
      |> Map.new(&binding_graph_entry/1)
      |> Map.put(alias_name, target)
      |> add_implicit_fallbacks()

    case find_alias_cycle(binding_map) do
      nil -> :ok
      cycle -> {:error, {:alias_cycle, cycle}}
    end
  end

  defp validate_alias_delete(alias_name) do
    binding_map =
      AliasBinding
      |> Repo.all()
      |> Map.new(&binding_graph_entry/1)
      |> Map.delete(alias_name)
      |> add_implicit_fallbacks()

    case find_alias_cycle(binding_map) do
      nil -> :ok
      cycle -> {:error, {:alias_cycle, cycle}}
    end
  end

  defp binding_graph_entry(%AliasBinding{target_kind: "alias"} = binding) do
    {:ok, target_alias} = normalize_alias(binding.target_alias_name)
    {alias_to_atom(binding.alias_name), {:alias, target_alias}}
  end

  defp binding_graph_entry(%AliasBinding{} = binding) do
    {alias_to_atom(binding.alias_name), {:provider, binding.target_provider_id}}
  end

  defp add_implicit_fallbacks(bindings) do
    bindings
    |> Map.put_new(:fast, {:alias, :default})
    |> Map.put_new(:heavy, {:alias, :default})
    |> Map.put_new(:compression, {:alias, :fast})
  end

  defp find_alias_cycle(bindings) do
    Enum.find_value(@aliases, &cycle_from(&1, bindings, []))
  end

  defp cycle_from(alias_name, bindings, path) do
    case alias_name in path do
      true ->
        Enum.reverse([alias_name | path])

      false ->
        case Map.get(bindings, alias_name) do
          {:alias, target_alias} -> cycle_from(target_alias, bindings, [alias_name | path])
          _other -> nil
        end
    end
  end

  defp upsert_alias_binding(alias_name, {:provider, %Provider{} = provider}) do
    attrs = %{
      alias_name: alias_to_string(alias_name),
      target_kind: "provider",
      target_provider_id: provider.id,
      target_alias_name: nil
    }

    do_upsert_alias_binding(attrs)
  end

  defp upsert_alias_binding(alias_name, {:alias, target_alias}) do
    attrs = %{
      alias_name: alias_to_string(alias_name),
      target_kind: "alias",
      target_provider_id: nil,
      target_alias_name: alias_to_string(target_alias)
    }

    do_upsert_alias_binding(attrs)
  end

  defp do_upsert_alias_binding(attrs) do
    Repo.transaction(fn ->
      case Repo.get_by(AliasBinding, alias_name: attrs.alias_name) do
        nil ->
          %AliasBinding{}
          |> AliasBinding.changeset(attrs)
          |> Repo.insert()

        %AliasBinding{} = binding ->
          binding
          |> AliasBinding.changeset(attrs)
          |> Repo.update()
      end
    end)
    |> unwrap_transaction()
  end

  defp unwrap_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_alias(value) when value in [:default, :fast, :heavy, :compression],
    do: {:ok, value}

  defp normalize_alias("default"), do: {:ok, :default}
  defp normalize_alias("fast"), do: {:ok, :fast}
  defp normalize_alias("heavy"), do: {:ok, :heavy}
  defp normalize_alias("compression"), do: {:ok, :compression}
  defp normalize_alias(value), do: {:error, {:unknown_alias, value}}

  defp alias_to_string(:default), do: "default"
  defp alias_to_string(:fast), do: "fast"
  defp alias_to_string(:heavy), do: "heavy"
  defp alias_to_string(:compression), do: "compression"

  defp alias_to_atom("default"), do: :default
  defp alias_to_atom("fast"), do: :fast
  defp alias_to_atom("heavy"), do: :heavy
  defp alias_to_atom("compression"), do: :compression
end
