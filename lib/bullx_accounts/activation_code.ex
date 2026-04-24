defmodule BullXAccounts.ActivationCode do
  @moduledoc """
  Single-use preauth credential for activating an unmatched channel actor.

  The plaintext code is never stored. Used rows remain in PostgreSQL for
  audit, including the channel actor that consumed the code.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "activation_codes" do
    field :code_hash, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :used_by_adapter, :string
    field :used_by_channel_id, :string
    field :used_by_external_id, :string
    field :metadata, :map, default: %{}

    belongs_to :created_by_user, BullXAccounts.User

    timestamps()
  end

  def changeset(activation_code, attrs) do
    activation_code
    |> cast(attrs, [
      :code_hash,
      :expires_at,
      :created_by_user_id,
      :revoked_at,
      :used_at,
      :used_by_adapter,
      :used_by_channel_id,
      :used_by_external_id,
      :metadata
    ])
    |> validate_required([:code_hash, :expires_at, :metadata])
    |> assoc_constraint(:created_by_user)
    |> unique_constraint(:code_hash)
  end
end
