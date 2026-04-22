defmodule BullXGateway.ControlPlane.Dispatch do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gateway_dispatches" do
    field :op, :string
    field :channel_adapter, :string
    field :channel_tenant, :string
    field :scope_id, :string
    field :thread_id, :string
    field :caused_by_signal_id, :string
    field :payload, :map
    field :status, :string
    field :attempts, :integer, default: 0
    field :max_attempts, :integer
    field :available_at, :utc_datetime_usec
    field :last_error, :map

    timestamps()
  end

  @statuses ~w(queued running retry_scheduled)

  def changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, [
      :id,
      :op,
      :channel_adapter,
      :channel_tenant,
      :scope_id,
      :thread_id,
      :caused_by_signal_id,
      :payload,
      :status,
      :attempts,
      :max_attempts,
      :available_at,
      :last_error
    ])
    |> validate_required([
      :id,
      :op,
      :channel_adapter,
      :channel_tenant,
      :scope_id,
      :payload,
      :status,
      :max_attempts
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:op, ~w(send edit stream))
    |> unique_constraint(:id, name: "gateway_dispatches_pkey")
  end

  def update_changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, [:status, :attempts, :available_at, :last_error])
    |> validate_inclusion(:status, @statuses)
  end
end
