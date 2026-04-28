defmodule BullXAccounts.AuthZ.ComputedGroup do
  @moduledoc """
  Validate and evaluate computed user group expressions.

  Expressions are JSON-compatible data, never Elixir code. Supported
  operations:

    * `and`: all child expressions must be true.
    * `or`: at least one child expression must be true.
    * `not`: the child expression must be false.
    * `group_member`: the user must be a member of another group.
    * `user_status`: the user must have the given `users.status`.

  Cycles, malformed shapes, and unknown group references evaluate to
  `false` at runtime; write-time validation rejects them.
  """

  import Ecto.Query

  require Logger

  alias BullX.Repo
  alias BullXAccounts.User
  alias BullXAccounts.UserGroup
  alias BullXAccounts.UserGroupMembership

  @valid_statuses ~w(active banned)

  @type expression :: map()
  @type validation_error ::
          :invalid_shape
          | :unknown_op
          | {:unknown_group, String.t()}
          | :cycle_detected
          | :empty_args
          | :invalid_arity
          | {:invalid_user_status, term()}

  @doc """
  Validate the shape of a computed-group expression. Use `:write` mode to
  reject `group_member` references to unknown groups; `:runtime` mode
  performs only structural validation.
  """
  @spec validate_expression(term(), keyword()) :: :ok | {:error, validation_error()}
  def validate_expression(expression, opts \\ []) do
    mode = Keyword.get(opts, :mode, :write)
    root_group_id = Keyword.get(opts, :root_group_id)
    root_group_name = Keyword.get(opts, :root_group_name)

    do_validate(expression, mode, root_group_id, root_group_name, %{})
  end

  @doc """
  Evaluate a persisted computed-group expression for a user.

  Returns `true` or `false`. Malformed shapes, unknown groups, or cycles
  evaluate to `false` and emit a single
  `[:bullx, :authz, :invalid_persisted_data]` event per faulty branch.
  """
  @spec evaluate(expression(), User.t(), keyword()) :: boolean()
  def evaluate(expression, %User{} = user, opts \\ []) do
    visited = Keyword.get(opts, :visited, %{})
    group_id = Keyword.get(opts, :group_id)

    case do_evaluate(expression, user, visited) do
      {:ok, result} ->
        result

      {:error, reason} ->
        emit_invalid_persisted_data(group_id, reason)
        false
    end
  end

  @doc """
  Whether `expression` references the given group name through any
  `group_member` operation. Tolerates atom or string keys.
  """
  @spec references_group?(term(), String.t()) :: boolean()
  def references_group?(expression, group_name) when is_binary(group_name) do
    do_references_group?(expression, group_name)
  end

  @doc """
  Compute the set of currently-true computed group ids for a user.

  Returns `{static_group_ids, computed_group_ids}` where each is a list of
  UUID strings.
  """
  @spec resolve_groups(User.t()) :: {[Ecto.UUID.t()], [Ecto.UUID.t()]}
  def resolve_groups(%User{} = user) do
    static_group_ids = list_static_group_ids(user)

    computed_group_ids =
      list_computed_groups()
      |> Enum.filter(fn group ->
        evaluate(group.computed_expression, user, group_id: group.id)
      end)
      |> Enum.map(& &1.id)

    {static_group_ids, computed_group_ids}
  end

  defp list_static_group_ids(%User{id: user_id}) do
    Repo.all(
      from membership in UserGroupMembership,
        where: membership.user_id == ^user_id,
        select: membership.group_id
    )
  end

  defp list_computed_groups do
    Repo.all(from group in UserGroup, where: group.type == :computed)
  end

  defp do_validate(%{} = expression, mode, root_group_id, root_group_name, visited) do
    expression = stringify_keys(expression)

    case Map.get(expression, "op") do
      "and" ->
        validate_args(expression, mode, root_group_id, root_group_name, visited)

      "or" ->
        validate_args(expression, mode, root_group_id, root_group_name, visited)

      "not" ->
        validate_not(expression, mode, root_group_id, root_group_name, visited)

      "group_member" ->
        validate_group_member(expression, mode, root_group_id, root_group_name, visited)

      "user_status" ->
        validate_user_status(expression)

      nil ->
        {:error, :invalid_shape}

      _other ->
        {:error, :unknown_op}
    end
  end

  defp do_validate(_expression, _mode, _root_group_id, _root_group_name, _visited),
    do: {:error, :invalid_shape}

  defp do_references_group?(%{} = expression, group_name) do
    case stringify_keys(expression) do
      %{"op" => "group_member", "group" => ^group_name} ->
        true

      %{"op" => op, "args" => args} when op in ["and", "or"] and is_list(args) ->
        Enum.any?(args, &do_references_group?(&1, group_name))

      %{"op" => "not", "arg" => arg} ->
        do_references_group?(arg, group_name)

      _other ->
        false
    end
  end

  defp do_references_group?(_expression, _group_name), do: false

  defp validate_args(expression, mode, root_group_id, root_group_name, visited) do
    case Map.get(expression, "args") do
      [_ | _] = args ->
        Enum.reduce_while(args, :ok, fn arg, :ok ->
          case do_validate(arg, mode, root_group_id, root_group_name, visited) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      [] ->
        {:error, :empty_args}

      _other ->
        {:error, :invalid_shape}
    end
  end

  defp validate_not(expression, mode, root_group_id, root_group_name, visited) do
    case Map.get(expression, "arg") do
      nil -> {:error, :invalid_arity}
      arg -> do_validate(arg, mode, root_group_id, root_group_name, visited)
    end
  end

  defp validate_group_member(expression, mode, root_group_id, root_group_name, visited) do
    case Map.get(expression, "group") do
      group when is_binary(group) and group != "" ->
        case mode do
          :write -> validate_group_reference(group, root_group_id, root_group_name, visited)
          :runtime -> :ok
        end

      _other ->
        {:error, :invalid_shape}
    end
  end

  defp validate_user_status(expression) do
    case Map.get(expression, "eq") do
      status when status in @valid_statuses -> :ok
      _other -> {:error, {:invalid_user_status, Map.get(expression, "eq")}}
    end
  end

  defp validate_group_reference(group_name, root_group_id, root_group_name, visited) do
    case group_name == root_group_name do
      true ->
        {:error, :cycle_detected}

      false ->
        validate_persisted_group_reference(group_name, root_group_id, root_group_name, visited)
    end
  end

  defp validate_persisted_group_reference(group_name, root_group_id, root_group_name, visited) do
    case Repo.get_by(UserGroup, name: group_name) do
      nil ->
        {:error, {:unknown_group, group_name}}

      %UserGroup{id: ^root_group_id} ->
        {:error, :cycle_detected}

      %UserGroup{type: :static} ->
        :ok

      %UserGroup{type: :computed, id: group_id, computed_expression: expression} ->
        case Map.has_key?(visited, group_id) do
          true ->
            {:error, :cycle_detected}

          false ->
            do_validate(
              expression,
              :write,
              root_group_id,
              root_group_name,
              Map.put(visited, group_id, true)
            )
        end
    end
  end

  defp do_evaluate(%{} = expression, user, visited) do
    expression = stringify_keys(expression)

    case Map.get(expression, "op") do
      "and" -> evaluate_and(Map.get(expression, "args"), user, visited)
      "or" -> evaluate_or(Map.get(expression, "args"), user, visited)
      "not" -> evaluate_not(Map.get(expression, "arg"), user, visited)
      "group_member" -> evaluate_group_member(Map.get(expression, "group"), user, visited)
      "user_status" -> evaluate_user_status(Map.get(expression, "eq"), user)
      _other -> {:error, :invalid_shape}
    end
  end

  defp do_evaluate(_expression, _user, _visited), do: {:error, :invalid_shape}

  defp evaluate_and([_ | _] = args, user, visited) do
    Enum.reduce_while(args, {:ok, true}, fn arg, _acc ->
      case do_evaluate(arg, user, visited) do
        {:ok, true} -> {:cont, {:ok, true}}
        {:ok, false} -> {:halt, {:ok, false}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_and(_args, _user, _visited), do: {:error, :invalid_shape}

  defp evaluate_or([_ | _] = args, user, visited) do
    Enum.reduce_while(args, {:ok, false}, fn arg, _acc ->
      case do_evaluate(arg, user, visited) do
        {:ok, true} -> {:halt, {:ok, true}}
        {:ok, false} -> {:cont, {:ok, false}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_or(_args, _user, _visited), do: {:error, :invalid_shape}

  defp evaluate_not(nil, _user, _visited), do: {:error, :invalid_arity}

  defp evaluate_not(arg, user, visited) do
    case do_evaluate(arg, user, visited) do
      {:ok, value} -> {:ok, not value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate_group_member(group_name, _user, _visited)
       when not is_binary(group_name) or group_name == "" do
    {:error, :invalid_shape}
  end

  defp evaluate_group_member(group_name, %User{} = user, visited) do
    case Repo.one(from group in UserGroup, where: group.name == ^group_name) do
      nil ->
        {:error, {:unknown_group, group_name}}

      %UserGroup{type: :static, id: group_id} ->
        {:ok, member_of_static_group?(user.id, group_id)}

      %UserGroup{type: :computed, id: group_id, computed_expression: expression} ->
        if Map.has_key?(visited, group_id) do
          {:error, :cycle_detected}
        else
          do_evaluate(expression, user, Map.put(visited, group_id, true))
        end
    end
  end

  defp evaluate_user_status(status, _user) when status not in @valid_statuses do
    {:error, {:invalid_user_status, status}}
  end

  defp evaluate_user_status(status, %User{status: user_status}) do
    {:ok, Atom.to_string(user_status) == status}
  end

  defp member_of_static_group?(user_id, group_id) do
    Repo.exists?(
      from membership in UserGroupMembership,
        where: membership.user_id == ^user_id and membership.group_id == ^group_id
    )
  end

  defp stringify_keys(%{} = map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      _other, acc -> acc
    end)
  end

  defp emit_invalid_persisted_data(group_id, reason) do
    Logger.error(
      "BullXAccounts.AuthZ.ComputedGroup: invalid persisted expression for group_id=#{inspect(group_id)} reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:bullx, :authz, :invalid_persisted_data],
      %{count: 1},
      %{kind: :computed_group, id: group_id, reason: reason}
    )
  end
end
