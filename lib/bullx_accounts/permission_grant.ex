defmodule BullXAccounts.PermissionGrant do
  @moduledoc """
  IAM-style permission grant assigned to one user or one group.

  Applicability is decided by principal, action equality, and
  `resource_pattern` matching. The Cedar `condition` expression is evaluated
  with caller request context only after applicability is established.
  """

  use Ecto.Schema

  import BullXAccounts.Changeset
  import Ecto.Changeset

  alias BullXAccounts.AuthZ.Cedar
  alias BullXAccounts.AuthZ.ResourcePattern

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "permission_grants" do
    field :resource_pattern, :string
    field :action, :string
    field :condition, :string, default: "true"
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :user, BullXAccounts.User
    belongs_to :group, BullXAccounts.UserGroup

    timestamps()
  end

  def changeset(grant, attrs) do
    has_condition? = condition_present?(attrs)

    grant
    |> cast(attrs, [
      :user_id,
      :group_id,
      :resource_pattern,
      :action,
      :description,
      :metadata
    ])
    |> normalize_blank([:resource_pattern, :action, :description])
    |> handle_condition(attrs, has_condition?)
    |> validate_required([:resource_pattern, :action, :condition, :metadata])
    |> validate_current_condition()
    |> validate_principal_exclusive()
    |> validate_resource_pattern()
    |> validate_action()
    |> assoc_constraint(:user)
    |> assoc_constraint(:group)
    |> check_constraint(:user_id,
      name: :permission_grants_principal_exclusive,
      message: "exactly one of user_id or group_id must be set"
    )
  end

  defp condition_present?(attrs) do
    Map.has_key?(attrs, :condition) or Map.has_key?(attrs, "condition")
  end

  defp condition_value(attrs) do
    Map.get(attrs, :condition, Map.get(attrs, "condition"))
  end

  defp handle_condition(changeset, _attrs, false) do
    case get_field(changeset, :condition) do
      nil -> put_change(changeset, :condition, "true")
      _existing -> changeset
    end
  end

  defp handle_condition(changeset, attrs, true) do
    case condition_value(attrs) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          add_error(changeset, :condition, "must not be empty")
        else
          put_change(changeset, :condition, trimmed)
        end

      nil ->
        add_error(changeset, :condition, "must not be empty")

      _other ->
        add_error(changeset, :condition, "must be a string")
    end
  end

  defp validate_condition_text(changeset, condition) do
    case Cedar.validate_condition(condition) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :condition, "is invalid: #{reason}")
    end
  end

  defp validate_current_condition(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_current_condition(changeset) do
    case get_field(changeset, :condition) do
      condition when is_binary(condition) -> validate_condition_text(changeset, condition)
      _other -> changeset
    end
  end

  defp validate_principal_exclusive(changeset) do
    user_id = get_field(changeset, :user_id)
    group_id = get_field(changeset, :group_id)

    case {user_id, group_id} do
      {nil, nil} ->
        changeset
        |> add_error(:user_id, "or group_id must be set")
        |> add_error(:group_id, "or user_id must be set")

      {_user, nil} ->
        changeset

      {nil, _group} ->
        changeset

      {_user, _group} ->
        changeset
        |> add_error(:user_id, "must be empty when group_id is set")
        |> add_error(:group_id, "must be empty when user_id is set")
    end
  end

  defp validate_resource_pattern(changeset) do
    case get_field(changeset, :resource_pattern) do
      nil ->
        changeset

      pattern ->
        case ResourcePattern.validate(pattern) do
          :ok -> changeset
          {:error, reason} -> add_error(changeset, :resource_pattern, reason)
        end
    end
  end

  defp validate_action(changeset) do
    case get_field(changeset, :action) do
      nil ->
        changeset

      action ->
        if String.contains?(action, ":") do
          add_error(changeset, :action, "must not contain ':'")
        else
          changeset
        end
    end
  end
end
