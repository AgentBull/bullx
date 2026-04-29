defmodule BullX.Runtime.Targets.Cache do
  @moduledoc false

  use GenServer

  import Ecto.Query

  require Logger

  alias BullX.Repo
  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Router
  alias BullX.Runtime.Targets.Target

  @targets_table :bullx_runtime_targets
  @routes_table :bullx_runtime_inbound_routes
  @table_opts [:named_table, :protected, :set, read_concurrency: true]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec refresh_all() :: :ok
  def refresh_all do
    call_if_running(:refresh_all)
  end

  @spec get_target(String.t()) :: {:ok, Target.t()} | :error
  def get_target(key) when is_binary(key), do: lookup(@targets_table, key)

  @spec list_targets() :: [Target.t()]
  def list_targets do
    @targets_table
    |> safe_tab2list()
    |> Enum.map(fn {_key, target} -> target end)
    |> Enum.sort_by(& &1.key)
  end

  @spec list_inbound_routes() :: [InboundRoute.t()]
  def list_inbound_routes do
    @routes_table
    |> lookup_value(:routes, [])
    |> Enum.sort_by(& &1.key)
  end

  @spec snapshot() :: %{
          router: Jido.Signal.Router.Router.t(),
          targets: %{String.t() => Target.t()},
          routes: %{String.t() => InboundRoute.t()}
        }
  def snapshot do
    routes = list_inbound_routes()

    %{
      router: lookup_value(@routes_table, :router, Router.empty()),
      targets: Map.new(list_targets(), &{&1.key, &1}),
      routes: Map.new(routes, &{&1.key, &1})
    }
  end

  @impl true
  def init(_opts) do
    :ets.new(@targets_table, @table_opts)
    :ets.new(@routes_table, @table_opts)
    load_all()
    {:ok, %{}}
  end

  @impl true
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

  defp load_all do
    targets = Repo.all(from(target in Target, order_by: target.key))

    routes =
      Repo.all(from(route in InboundRoute, order_by: [desc: route.priority, asc: route.key]))

    case Router.compile(routes) do
      {:ok, router} ->
        :ets.delete_all_objects(@targets_table)
        :ets.delete_all_objects(@routes_table)

        Enum.each(targets, &:ets.insert(@targets_table, {&1.key, &1}))
        :ets.insert(@routes_table, {:routes, routes})
        :ets.insert(@routes_table, {:router, router})

      {:error, reason} ->
        Logger.warning("BullX.Runtime.Targets.Cache failed to compile routes: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning(
        "BullX.Runtime.Targets.Cache failed to load from database, starting empty: #{Exception.message(error)}"
      )

      :ets.insert(@routes_table, {:routes, []})
      :ets.insert(@routes_table, {:router, Router.empty()})
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

  defp lookup_value(table, key, default) do
    case lookup(table, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
