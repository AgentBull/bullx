defmodule BullXAccounts.AuthZ do
  @moduledoc false

  import Ecto.Query

  alias BullX.Repo
  alias BullXAccounts.AuthZ.Cache
  alias BullXAccounts.AuthZ.Cedar
  alias BullXAccounts.AuthZ.ComputedGroup
  alias BullXAccounts.AuthZ.Request
  alias BullXAccounts.AuthZ.ResourcePattern
  alias BullXAccounts.PermissionGrant
  alias BullXAccounts.User
  alias BullXAccounts.UserGroup
  alias BullXAccounts.UserGroupMembership

  require Logger

  @admin_group_name "admin"

  ## Authorization

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

  @spec allowed?(User.t() | Ecto.UUID.t() | nil, String.t(), String.t(), map()) :: boolean()
  def allowed?(user, resource, action, context \\ %{}) do
    case authorize(user, resource, action, context) do
      :ok -> true
      _other -> false
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

    grants = list_applicable_grants(user.id, group_ids, request)

    if any_grant_allows?(grants, request), do: :allow, else: :deny
  end

  defp any_grant_allows?(grants, request) do
    Enum.any?(grants, fn grant ->
      case Cedar.evaluate(grant.condition, request) do
        {:ok, true} ->
          true

        {:ok, false} ->
          false

        {:error, reason} ->
          emit_invalid_persisted_data(grant, reason)
          false
      end
    end)
  end

  defp emit_invalid_persisted_data(grant, reason) do
    if invalid_persisted_condition?(grant.condition) do
      Logger.error(
        "BullXAccounts.AuthZ: invalid persisted condition grant_id=#{inspect(grant.id)} reason=#{inspect(reason)}"
      )

      :telemetry.execute(
        [:bullx, :authz, :invalid_persisted_data],
        %{count: 1},
        %{kind: :condition, id: grant.id, reason: reason}
      )
    end
  end

  defp invalid_persisted_condition?(condition) do
    case Cedar.validate_condition(condition) do
      :ok -> false
      {:error, reason} -> not Cedar.nif_unavailable_reason?(reason)
    end
  end

  defp list_applicable_grants(user_id, group_ids, %Request{action: action, resource: resource}) do
    grants_query =
      from grant in PermissionGrant,
        where:
          grant.action == ^action and
            (grant.user_id == ^user_id or grant.group_id in ^group_ids)

    grants_query
    |> Repo.all()
    |> Enum.filter(fn grant -> ResourcePattern.match?(grant.resource_pattern, resource) end)
  end

  ## Group expansion

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
