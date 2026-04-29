defmodule BullX.Runtime.Targets do
  @moduledoc """
  Public Runtime facade for dynamic inbound routes and target execution.

  The cache is a reconstructible projection of PostgreSQL route/target rows.
  Writers update PostgreSQL first, then refresh the cache for subsequent turns.
  """

  alias BullX.Runtime.Targets.Cache
  alias BullX.Runtime.Targets.Executor
  alias BullX.Runtime.Targets.Router
  alias BullX.Runtime.Targets.Writer
  alias Jido.Signal

  defdelegate list_targets(), to: Cache
  defdelegate list_inbound_routes(), to: Cache
  defdelegate put_target(attrs), to: Writer
  defdelegate update_target(target, attrs), to: Writer
  defdelegate delete_target(key), to: Writer
  defdelegate put_inbound_route(attrs), to: Writer
  defdelegate update_inbound_route(route, attrs), to: Writer
  defdelegate delete_inbound_route(key), to: Writer
  defdelegate refresh_cache(), to: Cache, as: :refresh_all

  @spec resolve(Signal.t()) :: {:ok, map()} | {:error, term()}
  def resolve(%Signal{} = signal), do: Router.resolve(signal)

  @spec dispatch(Signal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(%Signal{} = signal, opts \\ []) do
    with {:ok, resolution} <- resolve(signal) do
      Executor.execute(resolution, signal, opts)
    end
  end
end
