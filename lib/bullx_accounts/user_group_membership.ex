defmodule BullXAccounts.UserGroupMembership do
  @moduledoc """
  Static membership row joining a BullX user to a static `BullXAccounts.UserGroup`.

  Computed group memberships are evaluated at runtime and never stored here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "user_group_memberships" do
    belongs_to :user, BullXAccounts.User, primary_key: true
    belongs_to :group, BullXAccounts.UserGroup, primary_key: true

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :group_id])
    |> validate_required([:user_id, :group_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:group)
    |> unique_constraint([:user_id, :group_id], name: :user_group_memberships_pkey)
  end
end
