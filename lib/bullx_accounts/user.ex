defmodule BullXAccounts.User do
  @moduledoc """
  Durable BullX identity used by Web, Gateway resolution, Runtime, and future AuthZ.

  Authentication only distinguishes active users from banned users. Group,
  role, and permission state intentionally lives outside this subsystem.
  """

  use Ecto.Schema

  import BullXAccounts.Changeset
  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :email, :string
    field :phone, :string
    field :display_name, :string
    field :avatar_url, :string
    field :status, Ecto.Enum, values: [:active, :banned], default: :active

    has_many :channel_bindings, BullXAccounts.UserChannelBinding

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :phone, :display_name, :avatar_url, :status])
    |> normalize_blank([:username, :email, :phone, :display_name, :avatar_url])
    |> update_change(:email, &String.downcase/1)
    |> validate_required([:display_name, :status])
    |> validate_format(:email, @email_format, message: "is not a valid email")
    |> normalize_phone()
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint(:phone)
  end

  defp normalize_phone(changeset) do
    case fetch_change(changeset, :phone) do
      {:ok, nil} ->
        changeset

      {:ok, phone} ->
        case BullX.Ext.phone_normalize_e164(phone) do
          e164 when is_binary(e164) -> put_change(changeset, :phone, e164)
          {:error, _reason} -> add_error(changeset, :phone, "is not a valid phone number")
        end

      :error ->
        changeset
    end
  end
end
