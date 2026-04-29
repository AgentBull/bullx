defmodule BullXAIAgent.LLM.AliasBinding do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @aliases ~w(default fast heavy compression)
  @target_kinds ~w(provider alias)

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "llm_alias_bindings" do
    field :alias_name, :string
    field :target_kind, :string
    field :target_provider_id, BullX.Ecto.UUIDv7
    field :target_alias_name, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:alias_name, :target_kind, :target_provider_id, :target_alias_name])
    |> validate_required([:alias_name, :target_kind])
    |> validate_inclusion(:alias_name, @aliases)
    |> validate_inclusion(:target_kind, @target_kinds)
    |> validate_inclusion(:target_alias_name, @aliases)
    |> validate_target_shape()
    |> validate_default_target()
    |> unique_constraint(:alias_name)
    |> foreign_key_constraint(:target_provider_id)
    |> check_constraint(:alias_name, name: :alias_name_in_set)
    |> check_constraint(:target_kind, name: :target_kind_in_set)
    |> check_constraint(:target_alias_name, name: :target_alias_name_in_set)
    |> check_constraint(:target_kind, name: :alias_binding_target_shape)
    |> check_constraint(:target_kind, name: :default_alias_must_target_provider)
  end

  defp validate_target_shape(changeset) do
    case get_field(changeset, :target_kind) do
      "provider" ->
        changeset
        |> validate_required([:target_provider_id])
        |> validate_empty(:target_alias_name, "must be blank for provider targets")

      "alias" ->
        changeset
        |> validate_required([:target_alias_name])
        |> validate_empty(:target_provider_id, "must be blank for alias targets")

      _other ->
        changeset
    end
  end

  defp validate_default_target(changeset) do
    case {get_field(changeset, :alias_name), get_field(changeset, :target_kind)} do
      {"default", "alias"} -> add_error(changeset, :target_kind, "default must target provider")
      _other -> changeset
    end
  end

  defp validate_empty(changeset, field, message) do
    case get_field(changeset, field) do
      nil -> changeset
      "" -> changeset
      _value -> add_error(changeset, field, message)
    end
  end
end
