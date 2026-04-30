defmodule BullX.Config.AppConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "app_configs" do
    field :value, :string
    field :type, Ecto.Enum, values: [:plain, :secret], default: :plain
    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:key, :value, :type])
    |> validate_required([:key, :value])
  end
end
