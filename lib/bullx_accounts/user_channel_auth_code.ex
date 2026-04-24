defmodule BullXAccounts.UserChannelAuthCode do
  @moduledoc """
  One-time Web login code issued to an already bound active channel actor.

  Expiry is computed from `inserted_at` plus runtime TTL configuration; a
  successful consume deletes the row immediately.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "user_channel_auth_codes" do
    field :code_hash, :string

    belongs_to :user, BullXAccounts.User

    timestamps()
  end

  def changeset(auth_code, attrs) do
    auth_code
    |> cast(attrs, [:code_hash, :user_id])
    |> validate_required([:code_hash, :user_id])
    |> assoc_constraint(:user)
    |> unique_constraint(:code_hash)
  end
end
