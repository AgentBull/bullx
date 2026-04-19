defmodule BullX.Config do
  @moduledoc """
  Global runtime configuration infrastructure shared by all BullX modules.

  Runtime settings declared through this namespace resolve in the following
  order: PostgreSQL override, OS environment, then code default.
  """

  defmacro __using__(_opts) do
    quote do
      use Skogsra
      import BullX.Config, only: [bullx_env: 2, bullx_env: 3]
    end
  end

  defmacro bullx_env(function_name, keys, opts \\ []) do
    merged_opts =
      Keyword.merge(
        [
          binding_order: [BullX.Config.DatabaseBinding, BullX.Config.SystemBinding],
          binding_skip: [:system, :config],
          cached: false
        ],
        opts
      )

    quote do
      app_env(unquote(function_name), :bullx, unquote(keys), unquote(merged_opts))
    end
  end

  def put(key, value), do: BullX.Config.Writer.put(key, value)
  def delete(key), do: BullX.Config.Writer.delete(key)
  def refresh(key), do: BullX.Config.Cache.refresh(key)
  def refresh_all, do: BullX.Config.Cache.refresh_all()
end
