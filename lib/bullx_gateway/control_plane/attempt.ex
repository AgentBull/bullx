defmodule BullXGateway.ControlPlane.Attempt do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "gateway_attempts" do
    field :dispatch_id, :string
    field :attempt, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :status, :string
    field :outcome, :map
    field :error, :map

    timestamps(inserted_at: :inserted_at)
  end

  @statuses ~w(running completed failed)

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :id,
      :dispatch_id,
      :attempt,
      :started_at,
      :finished_at,
      :status,
      :outcome,
      :error
    ])
    |> validate_required([:id, :dispatch_id, :attempt, :started_at, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
