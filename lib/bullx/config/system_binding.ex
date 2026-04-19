defmodule BullX.Config.SystemBinding do
  use Skogsra.Binding

  @impl Skogsra.Binding
  def get_env(%Skogsra.Env{} = env, _state) do
    namespace = Skogsra.Env.gen_namespace(env)
    app_name = Skogsra.Env.gen_app_name(env)
    keys = Skogsra.Env.gen_keys(env)
    os_var = "#{namespace}#{app_name}_#{keys}"

    case System.get_env(os_var) do
      nil ->
        nil

      raw ->
        case Skogsra.Type.cast(env, raw) do
          {:ok, casted} ->
            case BullX.Config.Validation.validate_runtime(env, casted) do
              {:ok, _} -> {:ok, casted}
              {:error, _} -> nil
            end

          :error ->
            nil
        end
    end
  end
end
