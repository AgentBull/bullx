defmodule BullX.Config.Accounts.MatchRules do
  @moduledoc false

  use Skogsra.Type

  @bind_result "bind_existing_user"
  @create_result "allow_create_user"
  @bind_ops ~w(equals_user_field)
  @create_ops ~w(email_domain_in equals_any)
  @user_fields ~w(email phone username)

  @impl Skogsra.Type
  def cast(value) when is_list(value) do
    value
    |> Enum.map(&normalize_rule/1)
    |> valid_rules()
  end

  def cast(value) when is_binary(value) do
    with {:ok, decoded} <- Jason.decode(value) do
      cast(decoded)
    else
      _ -> :error
    end
  end

  def cast(_value), do: :error

  defp valid_rules(rules) do
    case Enum.all?(rules, &match?({:ok, _}, &1)) do
      true -> {:ok, Enum.map(rules, fn {:ok, rule} -> rule end)}
      false -> :error
    end
  end

  defp normalize_rule(rule) when is_map(rule) do
    rule = stringify_keys(rule)

    case rule do
      %{} ->
        case {Map.get(rule, "result"), Map.get(rule, "op")} do
          {@bind_result, op} when op in @bind_ops -> normalize_bind_rule(rule)
          {@create_result, op} when op in @create_ops -> normalize_create_rule(rule)
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp normalize_rule(_rule), do: :error

  defp normalize_bind_rule(rule) do
    with {:ok, source_path} <- required_string(rule, "source_path"),
         {:ok, user_field} <- required_string(rule, "user_field"),
         true <- user_field in @user_fields do
      {:ok,
       %{
         "result" => @bind_result,
         "op" => "equals_user_field",
         "source_path" => source_path,
         "user_field" => user_field
       }}
    else
      _ -> :error
    end
  end

  defp normalize_create_rule(%{"op" => "email_domain_in"} = rule) do
    with {:ok, source_path} <- required_string(rule, "source_path"),
         {:ok, domains} <- required_string_list(rule, "domains") do
      {:ok,
       %{
         "result" => @create_result,
         "op" => "email_domain_in",
         "source_path" => source_path,
         "domains" => Enum.map(domains, &String.downcase/1)
       }}
    else
      _ -> :error
    end
  end

  defp normalize_create_rule(%{"op" => "equals_any"} = rule) do
    with {:ok, source_path} <- required_string(rule, "source_path"),
         {:ok, values} <- required_string_list(rule, "values") do
      {:ok,
       %{
         "result" => @create_result,
         "op" => "equals_any",
         "source_path" => source_path,
         "values" => values
       }}
    else
      _ -> :error
    end
  end

  defp required_string(rule, key) do
    case Map.fetch(rule, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_string_list(rule, key) do
    case Map.fetch(rule, key) do
      {:ok, [_ | _] = values} ->
        values
        |> Enum.map(&string_value/1)
        |> valid_string_list()

      _ ->
        :error
    end
  end

  defp valid_string_list(values) do
    case Enum.all?(values, &match?({:ok, _}, &1)) do
      true -> {:ok, Enum.map(values, fn {:ok, value} -> value end)}
      false -> :error
    end
  end

  defp string_value(value) when is_binary(value) and value != "", do: {:ok, value}
  defp string_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp string_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp string_value(_value), do: :error

  defp stringify_keys(map) do
    Enum.reduce_while(map, %{}, fn
      {key, value}, acc when is_atom(key) -> {:cont, Map.put(acc, Atom.to_string(key), value)}
      {key, value}, acc when is_binary(key) -> {:cont, Map.put(acc, key, value)}
      {_key, _value}, _acc -> {:halt, :error}
    end)
  end
end

defmodule BullX.Config.Accounts do
  @moduledoc """
  Runtime configuration for BullXAccounts AuthN.

  Match rules are declarative JSON-compatible data and are validated before
  they are accepted from any runtime configuration layer.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:accounts_authn_match_rules,
    key: [:accounts, :authn_match_rules],
    type: BullX.Config.Accounts.MatchRules,
    default: []
  )

  @envdoc false
  bullx_env(:accounts_authn_auto_create_users,
    key: [:accounts, :authn_auto_create_users],
    type: :boolean,
    default: true
  )

  @envdoc false
  bullx_env(:accounts_authn_require_activation_code,
    key: [:accounts, :authn_require_activation_code],
    type: :boolean,
    default: true
  )

  @envdoc false
  bullx_env(:accounts_activation_code_ttl_seconds,
    key: [:accounts, :activation_code_ttl_seconds],
    type: :integer,
    default: 86_400,
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc false
  bullx_env(:accounts_web_auth_code_ttl_seconds,
    key: [:accounts, :web_auth_code_ttl_seconds],
    type: :integer,
    default: 300,
    zoi: Zoi.integer(gte: 1)
  )

  @envdoc false
  bullx_env(:accounts_authz_cache_ttl_ms,
    key: [:accounts, :authz_cache_ttl_ms],
    type: :integer,
    default: 60_000,
    zoi: Zoi.integer(gte: 0)
  )
end
