defmodule BullXGateway.ControlPlane.TriggerRecord do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gateway_trigger_records" do
    field :source, :string
    field :external_id, :string
    field :dedupe_key, :string
    field :signal_id, :string
    field :signal_type, :string
    field :event_category, :string
    field :duplex, :boolean
    field :channel_adapter, :string
    field :channel_tenant, :string
    field :scope_id, :string
    field :thread_id, :string
    field :signal_envelope, :map
    field :policy_outcome, :string
    field :published_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(trigger_record, attrs) do
    trigger_record
    |> cast(attrs, [
      :source,
      :external_id,
      :dedupe_key,
      :signal_id,
      :signal_type,
      :event_category,
      :duplex,
      :channel_adapter,
      :channel_tenant,
      :scope_id,
      :thread_id,
      :signal_envelope,
      :policy_outcome,
      :published_at
    ])
    |> validate_required([
      :source,
      :external_id,
      :dedupe_key,
      :signal_id,
      :signal_type,
      :event_category,
      :duplex,
      :channel_adapter,
      :channel_tenant,
      :scope_id,
      :signal_envelope,
      :policy_outcome
    ])
    |> unique_constraint(:dedupe_key,
      name: :gateway_trigger_records_dedupe_key_unpublished_index
    )
  end

  def update_changeset(trigger_record, attrs) do
    trigger_record
    |> cast(attrs, [:published_at])
  end
end
