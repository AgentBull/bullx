defmodule BullXGateway.ControlPlane.DedupeSeen do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:dedupe_key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gateway_dedupe_seen" do
    field :source, :string
    field :external_id, :string
    field :expires_at, :utc_datetime_usec
    field :seen_at, :utc_datetime_usec
  end

  def changeset(dedupe_seen, attrs) do
    dedupe_seen
    |> cast(attrs, [:dedupe_key, :source, :external_id, :expires_at, :seen_at])
    |> validate_required([:dedupe_key, :source, :external_id, :expires_at, :seen_at])
  end
end
