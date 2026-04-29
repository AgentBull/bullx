defmodule BullXAccounts.AuthZ do
  @moduledoc """
  AuthZ implementation for `BullXAccounts`.

  Provides authorization decisions, user-group management, and
  permission-grant CRUD. Public callers should go through the
  `BullXAccounts` facade.

  A decision is computed from three inputs:

    * **Static groups** — explicit `user_group_memberships` rows.
    * **Computed groups** — `user_groups` of type `:computed` whose
      `computed_expression` evaluates to true for the user at decision time.
    * **Permission grants** — IAM-style rows scoped to a single user **or**
      a single group, matched by exact action equality + resource pattern,
      then filtered by a Cedar `condition` expression evaluated against the
      request context.

  Decisions and group expansions are cached in ETS via
  `BullXAccounts.AuthZ.Cache`; every write path through this module
  invalidates the entire cache.
  """

  import Ecto.Query

  alias BullX.Repo
  alias BullXAccounts.AuthZ.Cache
  alias BullXAccounts.AuthZ.Cedar
  alias BullXAccounts.AuthZ.ComputedGroup
  alias BullXAccounts.AuthZ.Request
  alias BullXAccounts.PermissionGrant
  alias BullXAccounts.User
  alias BullXAccounts.UserGroup
  alias BullXAccounts.UserGroupMembership

  require Logger

  @admin_group_name "admin"

  ## Authorization

  @doc """
  Decide whether `user` may perform `action` on `resource`, optionally with
  request `context`.

  Returns:

    * `:ok` — allow.
    * `{:error, :forbidden}` — no grant matched, or all matching grants
      denied.
    * `{:error, :user_banned}` — principal is banned (regardless of grants).
    * `{:error, :not_found}` — the user disappeared between resolution
      and authorization.
    * `{:error, :invalid_request}` — any argument failed to normalize.

  Each unique `(user_id, resource, action, context)` decision is cached;
  context equality is by canonical hash so map ordering does not matter.
  """
  @spec authorize(User.t() | Ecto.UUID.t() | nil, String.t(), String.t(), map()) ::
          :ok
          | {:error, :forbidden}
          | {:error, :not_found}
          | {:error, :user_banned}
          | {:error, :invalid_request}
  def authorize(user, resource, action, context \\ %{}) do
    with {:ok, request} <- Request.build(user, resource, action, context),
         {:ok, user} <- load_active_user(request.user_id) do
      authorize_request(request, user)
    end
  end

  @doc """
  Convenience wrapper over `authorize/4` taking a single `"resource:action"`
  permission key.

  The key is split on the **last** `:` — resource ids may themselves contain
  `:` (e.g. `"app:foo:read"` resolves to resource `"app:foo"`, action
  `"read"`). A key without any `:` is `:invalid_request`.
  """
  @spec authorize_permission(User.t() | Ecto.UUID.t() | nil, String.t(), map()) ::
          :ok
          | {:error, :forbidden}
          | {:error, :not_found}
          | {:error, :user_banned}
          | {:error, :invalid_request}
  def authorize_permission(user, permission_key, context \\ %{}) do
    with {:ok, resource, action} <- split_permission(permission_key) do
      authorize(user, resource, action, context)
    end
  end

  @doc """
  Boolean form of `authorize/4`.

  Returns `false` for any non-`:ok` result, including bans and invalid
  requests — use `authorize/4` directly when error reasons matter.
  """
  @spec allowed?(User.t() | Ecto.UUID.t() | nil, String.t(), String.t(), map()) :: boolean()
  def allowed?(user, resource, action, context \\ %{}) do
    case authorize(user, resource, action, context) do
      :ok -> true
      _other -> false
    end
  end

  @doc false
  @spec ensure_built_in_admin_group() ::
          {:ok, UserGroup.t(), :created | :existing}
          | {:error, {:conflicting_admin_group, UserGroup.t()}}
          | {:error, Ecto.Changeset.t()}
  def ensure_built_in_admin_group do
    case Repo.get_by(UserGroup, name: @admin_group_name) do
      nil -> create_built_in_admin_group()
      %UserGroup{type: :static, built_in: true} = group -> {:ok, group, :existing}
      %UserGroup{} = group -> {:error, {:conflicting_admin_group, group}}
    end
  end

  @doc false
  @spec grant_bootstrap_admin(User.t()) ::
          :ok
          | {:error, {:conflicting_admin_group, UserGroup.t()}}
          | {:error, :not_found}
          | {:error, :computed_group}
          | {:error, Ecto.Changeset.t()}
  def grant_bootstrap_admin(%User{} = user) do
    with {:ok, group, _action} <- ensure_built_in_admin_group() do
      add_user_to_group(user, group)
    end
  end

  defp split_permission(permission) when is_binary(permission) do
    Request.split_permission_key(permission)
  end

  defp split_permission(_other), do: {:error, :invalid_request}

  defp load_active_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      %User{status: :active} = user -> {:ok, user}
      %User{status: :banned} -> {:error, :user_banned}
    end
  end

  defp create_built_in_admin_group do
    attrs = %{
      name: @admin_group_name,
      type: :static,
      description: "Built-in administrators group.",
      built_in: true
    }

    case %UserGroup{}
         |> UserGroup.system_create_changeset(attrs)
         |> Repo.insert() do
      {:ok, group} ->
        Cache.invalidate_all()
        {:ok, group, :created}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp authorize_request(%Request{} = request, %User{} = user) do
    cache_key = Request.cache_key(request)

    case Cache.fetch_decision(cache_key) do
      {:ok, :allow} ->
        :ok

      {:ok, :deny} ->
        {:error, :forbidden}

      :miss ->
        decision = evaluate_request(request, user)
        Cache.put_decision(cache_key, decision)
        finalize(decision)
    end
  end

  defp finalize(:allow), do: :ok
  defp finalize(:deny), do: {:error, :forbidden}

  defp evaluate_request(%Request{} = request, %User{} = user) do
    {static_group_ids, computed_group_ids} = effective_group_ids(user)
    group_ids = static_group_ids ++ computed_group_ids

    grants = list_candidate_grants(user.id, group_ids, request)

    if any_loaded_grant_allows?(grants, request), do: :allow, else: :deny
  end

  defp any_loaded_grant_allows?(grants, request) do
    loaded_grants = Enum.map(grants, &loaded_grant/1)

    case Cedar.eval_loaded_grants(request, loaded_grants) do
      {:ok, allowed?, invalid_grants} ->
        emit_invalid_persisted_conditions(invalid_grants)
        allowed?

      {:error, _reason} ->
        false
    end
  end

  defp loaded_grant(%PermissionGrant{} = grant) do
    {grant.id, grant.resource_pattern, grant.condition}
  end

  defp emit_invalid_persisted_conditions(invalid_grants) do
    Enum.each(invalid_grants, fn {grant_id, reason} ->
      Logger.error(
        "BullXAccounts.AuthZ: invalid persisted condition grant_id=#{inspect(grant_id)} reason=#{inspect(reason)}"
      )

      :telemetry.execute(
        [:bullx, :authz, :invalid_persisted_data],
        %{count: 1},
        %{kind: :condition, id: grant_id, reason: reason}
      )
    end)
  end

  defp list_candidate_grants(user_id, group_ids, %Request{action: action}) do
    Repo.all(
      from grant in PermissionGrant,
        where:
          grant.action == ^action and
            (grant.user_id == ^user_id or grant.group_id in ^group_ids)
    )
  end

  ## Group expansion

  @doc """
  List all groups the user currently belongs to, both static and computed.

  Computed-group membership is re-evaluated on each call (modulo cache) and
  is never persisted as rows.
  """
  @spec list_user_groups(User.t() | Ecto.UUID.t()) ::
          {:ok, [UserGroup.t()]} | {:error, :not_found}
  def list_user_groups(user_or_id) do
    with {:ok, user} <- fetch_user(user_or_id) do
      {static_ids, computed_ids} = effective_group_ids(user)
      ids = Enum.uniq(static_ids ++ computed_ids)

      groups = Repo.all(from group in UserGroup, where: group.id in ^ids)
      {:ok, groups}
    end
  end

  defp effective_group_ids(%User{id: user_id} = user) do
    case Cache.fetch_groups(user_id) do
      {:ok, value} ->
        value

      :miss ->
        value = ComputedGroup.resolve_groups(user)
        Cache.put_groups(user_id, value)
        value
    end
  end

  defp fetch_user(%User{} = user), do: {:ok, user}

  defp fetch_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(User, uuid) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_user(_other), do: {:error, :not_found}

  ## Group CRUD

  @doc "Create a user group. Public callers cannot pass `built_in: true` — the changeset ignores it; only `BullXAccounts.AuthZ.Bootstrap` can mint built-in groups."
  @spec create_user_group(map()) :: {:ok, UserGroup.t()} | {:error, Ecto.Changeset.t()}
  def create_user_group(attrs) do
    case %UserGroup{}
         |> UserGroup.create_changeset(attrs)
         |> Repo.insert() do
      {:ok, group} ->
        Cache.invalidate_all()
        {:ok, group}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Update a user group. `name`, `type`, and `built_in` are immutable here — only `description` and `computed_expression` can change."
  @spec update_user_group(UserGroup.t() | Ecto.UUID.t(), map()) ::
          {:ok, UserGroup.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_user_group(%UserGroup{} = group, attrs) do
    case group
         |> UserGroup.update_changeset(attrs)
         |> Repo.update() do
      {:ok, group} ->
        Cache.invalidate_all()
        {:ok, group}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_user_group(id, attrs) when is_binary(id) do
    with {:ok, group} <- fetch_group(id) do
      update_user_group(group, attrs)
    end
  end

  @doc """
  Delete a user group.

  Errors with `:built_in_group` for system-managed groups (e.g. the `admin`
  group) and `:group_in_use` when any other computed group's expression
  references this group by name. Resolve those references before deleting.
  """
  @spec delete_user_group(UserGroup.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found} | {:error, :built_in_group} | {:error, :group_in_use}
  def delete_user_group(%UserGroup{built_in: true}), do: {:error, :built_in_group}

  def delete_user_group(%UserGroup{} = group) do
    if group_referenced_by_computed?(group) do
      {:error, :group_in_use}
    else
      Repo.delete!(group)
      Cache.invalidate_all()
      :ok
    end
  end

  def delete_user_group(id) when is_binary(id) do
    with {:ok, group} <- fetch_group(id) do
      delete_user_group(group)
    end
  end

  defp group_referenced_by_computed?(%UserGroup{name: name, id: id}) do
    Repo.all(
      from group in UserGroup,
        where: group.type == :computed and group.id != ^id,
        select: group.computed_expression
    )
    |> Enum.any?(&ComputedGroup.references_group?(&1, name))
  end

  ## Membership

  @doc """
  Add a user to a static group.

  Computed groups reject membership writes with `:computed_group` — their
  membership is derived from the expression, not stored. Re-adding an
  existing member is a no-op (`on_conflict: :nothing`).
  """
  @spec add_user_to_group(User.t() | Ecto.UUID.t(), UserGroup.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found} | {:error, :computed_group} | {:error, Ecto.Changeset.t()}
  def add_user_to_group(user_or_id, group_or_id) do
    with {:ok, user} <- fetch_user(user_or_id),
         {:ok, group} <- fetch_group(group_or_id),
         :ok <- ensure_static_group(group) do
      attrs = %{user_id: user.id, group_id: group.id}

      case %UserGroupMembership{}
           |> UserGroupMembership.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing) do
        {:ok, _membership} ->
          Cache.invalidate_all()
          :ok

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Remove a user from a static group.

  The built-in `admin` group is protected: removing the last admin errors
  with `:last_admin_member`. The check runs under `SELECT ... FOR UPDATE`
  on the group row to prevent two concurrent removals from racing past it.
  """
  @spec remove_user_from_group(User.t() | Ecto.UUID.t(), UserGroup.t() | Ecto.UUID.t()) ::
          :ok
          | {:error, :not_found}
          | {:error, :computed_group}
          | {:error, :last_admin_member}
  def remove_user_from_group(user_or_id, group_or_id) do
    with {:ok, user} <- fetch_user(user_or_id),
         {:ok, group} <- fetch_group(group_or_id),
         :ok <- ensure_static_group(group) do
      remove_static_membership(user, group)
    end
  end

  defp ensure_static_group(%UserGroup{type: :static}), do: :ok
  defp ensure_static_group(%UserGroup{type: :computed}), do: {:error, :computed_group}

  defp remove_static_membership(%User{} = user, %UserGroup{
         id: group_id,
         built_in: true,
         name: @admin_group_name
       }) do
    Repo.transaction(fn ->
      case lock_group_for_update(group_id) do
        nil ->
          {:error, :not_found}

        group ->
          with :ok <- ensure_not_last_admin(group, user.id) do
            delete_membership(user, group)
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_static_membership(%User{} = user, %UserGroup{} = group) do
    delete_membership(user, group)
  end

  defp lock_group_for_update(group_id) do
    Repo.one(from group in UserGroup, where: group.id == ^group_id, lock: "FOR UPDATE")
  end

  defp delete_membership(%User{id: user_id}, %UserGroup{id: group_id}) do
    {count, _} =
      Repo.delete_all(
        from membership in UserGroupMembership,
          where: membership.user_id == ^user_id and membership.group_id == ^group_id
      )

    case count do
      0 ->
        {:error, :not_found}

      _ ->
        Cache.invalidate_all()
        :ok
    end
  end

  defp ensure_not_last_admin(%UserGroup{built_in: true, name: @admin_group_name, id: id}, user_id) do
    member_count =
      Repo.aggregate(
        from(m in UserGroupMembership, where: m.group_id == ^id and m.user_id != ^user_id),
        :count
      )

    if member_count == 0 do
      {:error, :last_admin_member}
    else
      :ok
    end
  end

  defp ensure_not_last_admin(_group, _user_id), do: :ok

  defp fetch_group(%UserGroup{} = group), do: {:ok, group}

  defp fetch_group(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(UserGroup, uuid) do
          nil -> {:error, :not_found}
          group -> {:ok, group}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_group(_other), do: {:error, :not_found}

  ## Permission grants

  @doc """
  Create a permission grant scoped to exactly one principal — either
  `user_id` or `group_id`, never both (a DB check constraint enforces this
  too).

  The `condition` is parsed and validated as a Cedar boolean expression at
  write time; invalid conditions are rejected before persistence.
  """
  @spec create_permission_grant(map()) ::
          {:ok, PermissionGrant.t()} | {:error, Ecto.Changeset.t()}
  def create_permission_grant(attrs) do
    case %PermissionGrant{}
         |> PermissionGrant.changeset(attrs)
         |> Repo.insert() do
      {:ok, grant} ->
        Cache.invalidate_all()
        {:ok, grant}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Update a permission grant. Same single-principal exclusivity and Cedar-condition validation as `create_permission_grant/1`."
  @spec update_permission_grant(PermissionGrant.t() | Ecto.UUID.t(), map()) ::
          {:ok, PermissionGrant.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_permission_grant(%PermissionGrant{} = grant, attrs) do
    case grant
         |> PermissionGrant.changeset(attrs)
         |> Repo.update() do
      {:ok, grant} ->
        Cache.invalidate_all()
        {:ok, grant}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_permission_grant(id, attrs) when is_binary(id) do
    with {:ok, grant} <- fetch_grant(id) do
      update_permission_grant(grant, attrs)
    end
  end

  @doc "Delete a permission grant."
  @spec delete_permission_grant(PermissionGrant.t() | Ecto.UUID.t()) ::
          :ok | {:error, :not_found}
  def delete_permission_grant(%PermissionGrant{} = grant) do
    Repo.delete!(grant)
    Cache.invalidate_all()
    :ok
  end

  def delete_permission_grant(id) when is_binary(id) do
    with {:ok, grant} <- fetch_grant(id) do
      delete_permission_grant(grant)
    end
  end

  defp fetch_grant(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(PermissionGrant, uuid) do
          nil -> {:error, :not_found}
          grant -> {:ok, grant}
        end

      :error ->
        {:error, :not_found}
    end
  end
end
