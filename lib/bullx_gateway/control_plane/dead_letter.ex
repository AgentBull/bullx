defmodule BullXGateway.ControlPlane.DeadLetter do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:dispatch_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gateway_dead_letters" do
    field :op, :string
    field :channel_adapter, :string
    field :channel_tenant, :string
    field :scope_id, :string
    field :thread_id, :string
    field :caused_by_signal_id, :string
    field :payload, :map
    field :final_error, :map
    field :attempts_total, :integer
    field :attempts_summary, :map
    field :dead_lettered_at, :utc_datetime_usec
    field :replay_count, :integer, default: 0
    field :archived_at, :utc_datetime_usec
  end

  def changeset(dead_letter, attrs) do
    dead_letter
    |> cast(attrs, [
      :dispatch_id,
      :op,
      :channel_adapter,
      :channel_tenant,
      :scope_id,
      :thread_id,
      :caused_by_signal_id,
      :payload,
      :final_error,
      :attempts_total,
      :attempts_summary,
      :dead_lettered_at,
      :replay_count,
      :archived_at
    ])
    |> validate_required([
      :dispatch_id,
      :op,
      :channel_adapter,
      :channel_tenant,
      :scope_id,
      :payload,
      :final_error,
      :attempts_total,
      :dead_lettered_at
    ])
  end
end
