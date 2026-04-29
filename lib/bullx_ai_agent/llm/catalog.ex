defmodule BullXAIAgent.LLM.Catalog do
  @moduledoc """
  Read API for the database-backed LLM provider catalog.

  Reads are served from `BullXAIAgent.LLM.Catalog.Cache`; process-local state is
  a reconstructible projection of PostgreSQL rows.
  """

  alias BullXAIAgent.LLM.Catalog.Cache
  alias BullXAIAgent.LLM.Provider
  alias BullXAIAgent.LLM.ProviderOptions
  alias BullXAIAgent.LLM.ResolvedProvider

  @aliases [:default, :fast, :heavy, :compression]
  @type alias_name :: :default | :fast | :heavy | :compression
  @type binding :: {:provider, String.t()} | {:alias, alias_name()}

  @spec list_providers() :: [Provider.t()]
  def list_providers, do: Cache.list_providers()

  @spec find_provider(String.t()) :: {:ok, Provider.t()} | {:error, :not_found}
  def find_provider(name) when is_binary(name) do
    case Cache.provider_by_name(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :not_found}
    end
  end

  @spec find_provider_by_id(String.t()) :: {:ok, Provider.t()} | {:error, :not_found}
  def find_provider_by_id(id) when is_binary(id) do
    case Cache.provider_by_id(id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :not_found}
    end
  end

  @spec list_alias_bindings() :: %{alias_name() => binding()}
  def list_alias_bindings, do: Cache.alias_bindings()

  @spec default_alias_configured?() :: boolean()
  def default_alias_configured? do
    match?({:ok, %ResolvedProvider{}}, resolve_alias(:default))
  end

  @spec resolve_alias(alias_name()) ::
          {:ok, ResolvedProvider.t()}
          | {:error,
             {:not_configured, :default}
             | {:alias_cycle, [alias_name()]}
             | {:decrypt_failed, String.t()}
             | {:invalid_provider_options, String.t(), term()}
             | {:unknown_provider, String.t()}
             | {:unknown_alias, term()}}
  def resolve_alias(alias_name) when alias_name in @aliases do
    do_resolve_alias(alias_name, [])
  end

  def resolve_alias(other), do: {:error, {:unknown_alias, other}}

  @spec resolve_provider(String.t()) ::
          {:ok, ResolvedProvider.t()}
          | {:error,
             {:decrypt_failed, String.t()}
             | {:invalid_provider_options, String.t(), term()}
             | {:unknown_provider, String.t()}}
  def resolve_provider(provider_name) when is_binary(provider_name) do
    do_resolve_provider(provider_name)
  end

  @spec resolve_alias!(alias_name()) :: ResolvedProvider.t() | no_return()
  def resolve_alias!(alias_name) do
    case resolve_alias(alias_name) do
      {:ok, resolved} ->
        resolved

      {:error, reason} ->
        raise ArgumentError,
              "Could not resolve LLM model alias #{inspect(alias_name)}: #{inspect(reason)}"
    end
  end

  defp do_resolve_alias(alias_name, path) do
    case alias_name in path do
      true ->
        {:error, {:alias_cycle, cycle_path(alias_name, path)}}

      false ->
        case Cache.alias_binding(alias_name) do
          {:ok, {:provider, provider_name}} -> do_resolve_provider(provider_name)
          {:ok, {:alias, target_alias}} -> do_resolve_alias(target_alias, [alias_name | path])
          :error -> resolve_unbound_alias(alias_name, [alias_name | path])
        end
    end
  end

  defp resolve_unbound_alias(:default, _path), do: {:error, {:not_configured, :default}}
  defp resolve_unbound_alias(:compression, path), do: do_resolve_alias(:fast, path)
  defp resolve_unbound_alias(_alias_name, path), do: do_resolve_alias(:default, path)

  defp cycle_path(alias_name, path), do: Enum.reverse([alias_name | path])

  defp do_resolve_provider(provider_name) do
    case Cache.provider_by_name(provider_name) do
      {:ok, %Provider{} = provider} -> build_resolved_provider(provider)
      :error -> {:error, {:unknown_provider, provider_name}}
    end
  end

  defp build_resolved_provider(%Provider{} = provider) do
    with {:ok, model} <- provider_model(provider),
         {:ok, opts} <- provider_opts(provider) do
      {:ok, %ResolvedProvider{model: model, opts: opts}}
    end
  end

  defp provider_model(%Provider{} = provider) do
    with {:ok, provider_id} <- provider_atom(provider.provider_id) do
      model =
        %{provider: provider_id, id: provider.model_id}
        |> maybe_put_base_url(provider.base_url)

      {:ok, model}
    end
  end

  defp provider_atom(provider_id) do
    ReqLLM.Providers.list()
    |> Enum.find(&(Atom.to_string(&1) == provider_id))
    |> case do
      nil -> {:error, {:unknown_provider, provider_id}}
      provider -> {:ok, provider}
    end
  end

  defp maybe_put_base_url(model, nil), do: model
  defp maybe_put_base_url(model, ""), do: model
  defp maybe_put_base_url(model, base_url), do: Map.put(model, :base_url, base_url)

  defp provider_opts(%Provider{encrypted_api_key: empty} = provider)
       when empty in [nil, ""] do
    provider_options_opt([], provider)
  end

  defp provider_opts(%Provider{} = provider) do
    case BullXAIAgent.LLM.Crypto.decrypt_api_key(provider.encrypted_api_key, provider.id) do
      {:ok, api_key} ->
        provider_options_opt([api_key: api_key], provider)

      {:error, _reason} ->
        {:error, {:decrypt_failed, provider.name}}
    end
  end

  defp provider_options_opt(opts, %Provider{provider_options: empty}) when empty in [%{}, nil],
    do: {:ok, opts}

  defp provider_options_opt(opts, %Provider{} = provider) do
    case ProviderOptions.normalize_for_request(provider.provider_id, provider.provider_options) do
      {:ok, provider_options} -> {:ok, Keyword.put(opts, :provider_options, provider_options)}
      {:error, reason} -> {:error, {:invalid_provider_options, provider.name, reason}}
    end
  end
end
