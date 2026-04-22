defmodule BullX.Config.DatabaseBinding do
  use Skogsra.Binding

  @impl Skogsra.Binding
  def get_env(%Skogsra.Env{} = env, _state) do
    key = to_db_key(env)

    case BullX.Config.Cache.get_raw(key) do
      {:ok, raw} ->
        case BullX.Config.Validation.validate_runtime_raw(env, raw) do
          :ok -> {:ok, raw}
          {:error, _} -> nil
        end

      :error ->
        nil
    end
  end

  defp to_db_key(%Skogsra.Env{app_name: app_name, keys: keys}) do
    key_parts = keys |> List.wrap() |> Enum.map(&Atom.to_string/1)
    Enum.join([Atom.to_string(app_name) | key_parts], ".")
  end
end
