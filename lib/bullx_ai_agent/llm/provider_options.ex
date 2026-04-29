defmodule BullXAIAgent.LLM.ProviderOptions do
  @moduledoc false

  @type provider_id :: String.t()
  @type options :: %{optional(String.t() | atom()) => term()}

  @spec normalize_for_storage(provider_id(), options()) :: {:ok, map()} | {:error, term()}
  def normalize_for_storage(provider_id, options)
      when is_binary(provider_id) and is_map(options) do
    with {:ok, schema} <- provider_schema(provider_id),
         {:ok, normalized} <- normalize_with_schema(options, schema),
         :ok <- validate_with_schema(normalized, schema) do
      {:ok, jsonable_options(normalized)}
    end
  end

  @spec normalize_for_request(provider_id(), options() | nil) ::
          {:ok, keyword()} | {:error, term()}
  def normalize_for_request(_provider_id, nil), do: {:ok, []}

  def normalize_for_request(provider_id, options)
      when is_binary(provider_id) and is_map(options) do
    with {:ok, schema} <- provider_schema(provider_id),
         {:ok, normalized} <- normalize_with_schema(options, schema),
         :ok <- validate_with_schema(normalized, schema) do
      {:ok, Map.to_list(normalized)}
    end
  end

  defp provider_schema(provider_id) do
    with {:ok, provider} <- provider_atom(provider_id),
         {:ok, module} <- ReqLLM.Providers.get(provider),
         true <- function_exported?(module, :provider_schema, 0) do
      {:ok, module.provider_schema()}
    else
      false -> {:ok, NimbleOptions.new!([])}
      {:error, reason} -> {:error, reason}
      nil -> {:error, {:unknown_req_llm_provider, provider_id}}
    end
  end

  defp provider_atom(provider_id) do
    ReqLLM.Providers.list()
    |> Enum.find(&(Atom.to_string(&1) == provider_id))
    |> case do
      nil -> {:error, {:unknown_req_llm_provider, provider_id}}
      provider -> {:ok, provider}
    end
  end

  defp normalize_with_schema(options, %NimbleOptions{schema: schema}) do
    schema_by_string = Map.new(schema, fn {key, opts} -> {Atom.to_string(key), {key, opts}} end)

    unknown_keys =
      options
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&Map.has_key?(schema_by_string, &1))

    case unknown_keys do
      [] ->
        {:ok,
         Map.new(options, fn {key, value} ->
           {schema_key, opts} = Map.fetch!(schema_by_string, to_string(key))
           {schema_key, normalize_value(Keyword.get(opts, :type, :any), value)}
         end)}

      [_ | _] ->
        {:error, {:unknown_options, unknown_keys}}
    end
  end

  defp validate_with_schema(normalized, schema) do
    case NimbleOptions.validate(Map.to_list(normalized), schema) do
      {:ok, _validated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_value({:or, types}, value) when is_list(types) do
    cond do
      is_binary(value) and Enum.any?(types, &(&1 == :string)) ->
        value

      is_binary(value) and Enum.any?(types, &exact_in_match?(&1, value)) ->
        value

      true ->
        types
        |> Enum.reduce_while(value, fn type, current ->
          normalized = normalize_value(type, value)

          case normalized == value do
            true -> {:cont, current}
            false -> {:halt, normalized}
          end
        end)
    end
  end

  defp normalize_value({:in, values}, value) do
    cond do
      value in values ->
        value

      is_binary(value) ->
        Enum.find(values, value, fn
          option when is_atom(option) -> Atom.to_string(option) == value
          option -> option == value
        end)

      true ->
        value
    end
  end

  defp normalize_value({:list, type}, values) when is_list(values) do
    Enum.map(values, &normalize_value(type, &1))
  end

  defp normalize_value(:map, value) when is_map(value), do: atomize_json_map(value)

  defp normalize_value(:atom, value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  defp normalize_value(type, value)
       when type in [:integer, :pos_integer, :non_neg_integer] and is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp normalize_value(:float, value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _other -> value
    end
  end

  defp normalize_value(:boolean, value) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _other -> value
    end
  end

  defp normalize_value(_type, value), do: value

  defp exact_in_match?({:in, values}, value), do: value in values
  defp exact_in_match?(_type, _value), do: false

  defp atomize_json_map(value) do
    Map.new(value, fn {key, item} -> {atomize_json_key(key), atomize_json_value(item)} end)
  end

  defp atomize_json_key(key) when is_atom(key), do: key
  defp atomize_json_key(key) when is_binary(key), do: String.to_atom(key)
  defp atomize_json_key(key), do: key

  defp atomize_json_value(value) when is_map(value), do: atomize_json_map(value)
  defp atomize_json_value(value) when is_list(value), do: Enum.map(value, &atomize_json_value/1)
  defp atomize_json_value(value), do: value

  defp jsonable_options(normalized) do
    Map.new(normalized, fn {key, value} -> {Atom.to_string(key), jsonable_value(value)} end)
  end

  defp jsonable_value(value) when is_boolean(value), do: value
  defp jsonable_value(nil), do: nil
  defp jsonable_value(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable_value(value) when is_list(value), do: Enum.map(value, &jsonable_value/1)

  defp jsonable_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), jsonable_value(item)} end)
  end

  defp jsonable_value(value), do: value
end
