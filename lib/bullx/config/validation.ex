defmodule BullX.Config.Validation do
  @doc """
  Validates a casted value against the optional Zoi schema declared on a
  Skogsra env. Returns `{:ok, value}` on success or `{:error, :invalid}` on
  failure, allowing the binding pipeline to fall through to the next source.
  """
  def validate_runtime(env_or_opts, value) do
    case extract_zoi(env_or_opts) do
      nil ->
        {:ok, value}

      schema ->
        case Zoi.parse(schema, value) do
          {:ok, _} -> {:ok, value}
          {:error, _} -> {:error, :invalid}
        end
    end
  end

  @doc """
  Validates a value against Zoi at bootstrap time. Raises with a descriptive
  message on failure instead of returning an error tuple.
  """
  def validate_bootstrap!(value, opts) when is_list(opts) do
    case Keyword.get(opts, :zoi) do
      nil ->
        value

      schema_or_fn ->
        schema = normalize_schema(schema_or_fn)

        case Zoi.parse(schema, value) do
          {:ok, _} ->
            value

          {:error, errors} ->
            raise "BullX.Config.Bootstrap validation failed for value #{inspect(value)}: #{inspect(errors)}"
        end
    end
  end

  defp extract_zoi(%Skogsra.Env{options: options}) do
    normalize_schema(Keyword.get(options || [], :zoi))
  end

  defp extract_zoi(opts) when is_list(opts) do
    normalize_schema(Keyword.get(opts, :zoi))
  end

  defp normalize_schema(nil), do: nil
  defp normalize_schema(fun) when is_function(fun, 0), do: fun.()
  defp normalize_schema(schema), do: schema
end
