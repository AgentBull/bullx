defmodule BullXAccounts.UserGroup do
  @moduledoc """
  Static or computed group of BullX users.

  Static groups have administrator-managed memberships in
  `user_group_memberships`. Computed groups derive membership at runtime from
  `computed_expression` and never store rows in `user_group_memberships`.

  Group `name` and `type` are immutable after creation. The `built_in` flag
  is system-owned; public create/update changesets ignore caller-supplied
  `built_in` values.
  """

  use Ecto.Schema

  import BullXAccounts.Changeset
  import Ecto.Changeset

  alias BullXAccounts.AuthZ.ComputedGroup

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "user_groups" do
    field :name, :string
    field :type, Ecto.Enum, values: [:static, :computed]
    field :description, :string
    field :computed_expression, :map
    field :built_in, :boolean, default: false

    has_many :memberships, BullXAccounts.UserGroupMembership, foreign_key: :group_id

    timestamps()
  end

  @doc """
  Public create changeset. `built_in` is system-owned and ignored here.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :type, :description, :computed_expression])
    |> common_validations()
  end

  @doc """
  Internal create changeset used by AuthZ bootstrap to create built-in groups.
  """
  @spec system_create_changeset(t(), map()) :: Ecto.Changeset.t()
  def system_create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :type, :description, :computed_expression, :built_in])
    |> common_validations()
  end

  @doc """
  Public update changeset. `name`, `type`, and `built_in` are immutable here.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [:description, :computed_expression])
    |> validate_type_expression_invariant()
    |> validate_computed_expression()
    |> check_constraint(:computed_expression,
      name: :user_groups_expression_matches_type,
      message: "must be present for computed groups and absent for static groups"
    )
  end

  defp common_validations(changeset) do
    changeset
    |> normalize_blank([:name, :description])
    |> validate_required([:name, :type])
    |> validate_length(:name, min: 1)
    |> validate_type_expression_invariant()
    |> validate_computed_expression()
    |> unique_constraint(:name)
    |> check_constraint(:name,
      name: :user_groups_name_present,
      message: "must not be empty"
    )
    |> check_constraint(:computed_expression,
      name: :user_groups_expression_matches_type,
      message: "must be present for computed groups and absent for static groups"
    )
  end

  defp validate_type_expression_invariant(changeset) do
    type = get_field(changeset, :type)
    expression = get_field(changeset, :computed_expression)

    case {type, expression} do
      {:static, nil} ->
        changeset

      {:static, _expression} ->
        add_error(changeset, :computed_expression, "must be empty for static groups")

      {:computed, nil} ->
        add_error(changeset, :computed_expression, "must be present for computed groups")

      {:computed, _expression} ->
        changeset

      {nil, _expression} ->
        changeset
    end
  end

  defp validate_computed_expression(changeset) do
    case get_field(changeset, :type) do
      :computed -> validate_computed_expression_shape(changeset)
      _other -> changeset
    end
  end

  defp validate_computed_expression_shape(changeset) do
    case get_field(changeset, :computed_expression) do
      nil ->
        changeset

      expression ->
        case ComputedGroup.validate_expression(expression,
               root_group_id: get_field(changeset, :id),
               root_group_name: get_field(changeset, :name)
             ) do
          :ok ->
            changeset

          {:error, reason} ->
            add_error(changeset, :computed_expression, "is invalid: #{inspect(reason)}")
        end
    end
  end
end
