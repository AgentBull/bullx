defmodule BullX.Config.SecretKeys do
  @moduledoc false

  @bullx_prefix "Elixir.BullX.Config."

  @doc """
  Returns `true` if the given DB key was declared with `secret: true` in any
  `use BullX.Config` module.
  """
  @spec secret?(String.t()) :: boolean()
  def secret?(key) when is_binary(key) do
    MapSet.member?(keys(), key)
  end

  @doc "Clears the cached key set. Used in tests to force a fresh build."
  def reset do
    :persistent_term.erase({__MODULE__, :keys})
    :ok
  end

  defp keys do
    case :persistent_term.get({__MODULE__, :keys}, :unset) do
      :unset ->
        built = build()
        :persistent_term.put({__MODULE__, :keys}, built)
        built

      existing ->
        existing
    end
  end

  defp build do
    :code.all_loaded()
    |> Enum.flat_map(fn {mod, _} ->
      mod_str = Atom.to_string(mod)

      if String.starts_with?(mod_str, @bullx_prefix) and
           function_exported?(mod, :__bullx_secret_keys__, 0) do
        mod.__bullx_secret_keys__()
      else
        []
      end
    end)
    |> MapSet.new()
  end
end
