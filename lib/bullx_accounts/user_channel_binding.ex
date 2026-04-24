defmodule BullXAccounts.UserChannelBinding do
  @moduledoc """
  Durable binding between a BullX user and a Gateway channel actor.

  Gateway actors remain channel-local. This schema is the stable lookup from
  `{adapter, channel_id, external_id}` to a BullX identity.
  """

  use Ecto.Schema

  import BullXAccounts.Changeset
  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "user_channel_bindings" do
    field :adapter, :string
    field :channel_id, :string
    field :external_id, :string
    field :metadata, :map, default: %{}

    belongs_to :user, BullXAccounts.User

    timestamps()
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:user_id, :adapter, :channel_id, :external_id, :metadata])
    |> normalize_blank([:adapter, :channel_id, :external_id])
    |> validate_required([:user_id, :adapter, :channel_id, :external_id, :metadata])
    |> assoc_constraint(:user)
    |> unique_constraint([:adapter, :channel_id, :external_id],
      name: :user_channel_bindings_actor_index
    )
  end
end
