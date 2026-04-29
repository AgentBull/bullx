defmodule BullXAIAgent.LLM.Catalog.Cache do
  @moduledoc false

  use GenServer

  import Ecto.Query

  require Logger

  alias BullX.Repo
  alias BullXAIAgent.LLM.AliasBinding
  alias BullXAIAgent.LLM.Provider

  @providers_table :bullx_llm_providers
  @aliases_table :bullx_llm_alias_bindings
  @table_opts [:named_table, :protected, :set, read_concurrency: true]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list_providers() :: [Provider.t()]
  def list_providers do
    @providers_table
    |> safe_tab2list()
    |> Enum.flat_map(fn
      {{:name, _name}, %Provider{} = provider} -> [provider]
      _entry -> []
    end)
    |> Enum.sort_by(& &1.name)
  end

  @spec provider_by_name(String.t()) :: {:ok, Provider.t()} | :error
  def provider_by_name(name) when is_binary(name) do
    lookup(@providers_table, {:name, name})
  end

  @spec provider_by_id(binary()) :: {:ok, Provider.t()} | :error
  def provider_by_id(id) when is_binary(id) do
    lookup(@providers_table, {:id, id})
  end

  @spec alias_bindings() :: %{
          BullXAIAgent.LLM.Catalog.alias_name() => BullXAIAgent.LLM.Catalog.binding()
        }
  def alias_bindings do
    @aliases_table
    |> safe_tab2list()
    |> Map.new()
  end

  @spec alias_binding(BullXAIAgent.LLM.Catalog.alias_name()) ::
          {:ok, BullXAIAgent.LLM.Catalog.binding()} | :error
  def alias_binding(alias_name) when is_atom(alias_name) do
    lookup(@aliases_table, alias_name)
  end

  @spec refresh_provider(String.t()) :: :ok
  def refresh_provider(name) when is_binary(name) do
    call_if_running({:refresh_provider, name})
  end

  @spec refresh_alias(BullXAIAgent.LLM.Catalog.alias_name()) :: :ok
  def refresh_alias(alias_name) when is_atom(alias_name) do
    call_if_running({:refresh_alias, alias_name})
  end

  @spec refresh_all() :: :ok
  def refresh_all do
    call_if_running(:refresh_all)
  end

  @impl true
  def init(_opts) do
    :ets.new(@providers_table, @table_opts)
    :ets.new(@aliases_table, @table_opts)
    load_all()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:refresh_provider, name}, _from, state) do
    do_refresh_provider(name)
    {:reply, :ok, state}
  end

  def handle_call({:refresh_alias, alias_name}, _from, state) do
    do_refresh_alias(alias_name)
    {:reply, :ok, state}
  end

  def handle_call(:refresh_all, _from, state) do
    load_all()
    {:reply, :ok, state}
  end

  defp call_if_running(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp lookup(table, key) do
    try do
      case :ets.lookup(table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  defp load_all do
    providers = Repo.all(from(provider in Provider, order_by: provider.name))
    bindings = Repo.all(from(binding in AliasBinding, order_by: binding.alias_name))

    providers_by_id = Map.new(providers, &{&1.id, &1})

    :ets.delete_all_objects(@providers_table)
    :ets.delete_all_objects(@aliases_table)

    Enum.each(providers, &insert_provider/1)
    Enum.each(bindings, &insert_alias_binding(&1, providers_by_id))
  rescue
    error ->
      Logger.warning(
        "BullXAIAgent.LLM.Catalog.Cache failed to load from database, starting empty: #{Exception.message(error)}"
      )
  end

  defp do_refresh_provider(name) do
    cached = provider_by_name(name)

    case Repo.get_by(Provider, name: name) do
      nil ->
        delete_provider_entries(name, cached)

      %Provider{} = provider ->
        delete_provider_entries(name, cached)
        insert_provider(provider)
    end
  rescue
    error ->
      Logger.warning(
        "BullXAIAgent.LLM.Catalog.Cache failed to refresh provider #{inspect(name)}: #{Exception.message(error)}"
      )
  end

  defp do_refresh_alias(alias_name) do
    case Repo.get_by(AliasBinding, alias_name: alias_to_string(alias_name)) do
      nil ->
        :ets.delete(@aliases_table, alias_name)

      %AliasBinding{} = binding ->
        :ets.delete(@aliases_table, alias_name)
        insert_alias_binding(binding, provider_map_from_cache())
    end
  rescue
    error ->
      Logger.warning(
        "BullXAIAgent.LLM.Catalog.Cache failed to refresh alias #{inspect(alias_name)}: #{Exception.message(error)}"
      )
  end

  defp provider_map_from_cache do
    @providers_table
    |> safe_tab2list()
    |> Enum.flat_map(fn
      {{:id, id}, %Provider{} = provider} -> [{id, provider}]
      _entry -> []
    end)
    |> Map.new()
  end

  defp delete_provider_entries(name, {:ok, %Provider{id: id}}) do
    :ets.delete(@providers_table, {:name, name})
    :ets.delete(@providers_table, {:id, id})
  end

  defp delete_provider_entries(name, :error) do
    :ets.delete(@providers_table, {:name, name})
  end

  defp insert_provider(%Provider{} = provider) do
    :ets.insert(@providers_table, {{:name, provider.name}, provider})
    :ets.insert(@providers_table, {{:id, provider.id}, provider})
  end

  defp insert_alias_binding(%AliasBinding{target_kind: "provider"} = binding, providers_by_id) do
    case Map.get(providers_by_id, binding.target_provider_id) do
      %Provider{name: provider_name} ->
        :ets.insert(
          @aliases_table,
          {alias_to_atom(binding.alias_name), {:provider, provider_name}}
        )

      nil ->
        :ok
    end
  end

  defp insert_alias_binding(%AliasBinding{target_kind: "alias"} = binding, _providers_by_id) do
    :ets.insert(
      @aliases_table,
      {alias_to_atom(binding.alias_name), {:alias, alias_to_atom(binding.target_alias_name)}}
    )
  end

  defp alias_to_string(:default), do: "default"
  defp alias_to_string(:fast), do: "fast"
  defp alias_to_string(:heavy), do: "heavy"
  defp alias_to_string(:compression), do: "compression"

  defp alias_to_atom("default"), do: :default
  defp alias_to_atom("fast"), do: :fast
  defp alias_to_atom("heavy"), do: :heavy
  defp alias_to_atom("compression"), do: :compression
end
