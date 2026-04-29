defmodule BullXAIAgent.LLM.Provider do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "llm_providers" do
    field :name, :string
    field :provider_id, :string
    field :model_id, :string
    field :base_url, :string
    field :encrypted_api_key, :string
    field :provider_options, :map, default: %{}

    timestamps()
  end

  @required ~w(name provider_id model_id)a
  @optional ~w(base_url encrypted_api_key provider_options)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_format(:name, ~r/^[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,192}$/)
    |> validate_length(:provider_id, min: 1, max: 64)
    |> validate_length(:model_id, min: 1, max: 128)
    |> unique_constraint(:name)
  end

  @spec delete_changeset(t()) :: Ecto.Changeset.t()
  def delete_changeset(provider) do
    provider
    |> change()
    |> foreign_key_constraint(:id, name: :llm_alias_bindings_target_provider_id_fkey)
  end
end
