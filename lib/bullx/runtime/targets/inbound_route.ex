defmodule BullX.Runtime.Targets.InboundRoute do
  @moduledoc """
  Persisted fixed-column inbound route.

  Nullable match fields are wildcards. Runtime compiles these rows into a
  `Jido.Signal.Router` and applies BullX-specific priority and specificity
  ordering after route collection.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.Runtime.Targets.Target

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "runtime_inbound_routes" do
    field :name, :string
    field :priority, :integer, default: 0
    field :signal_pattern, :string, default: "com.agentbull.x.inbound.**"
    field :adapter, :string
    field :channel_id, :string
    field :scope_id, :string
    field :thread_id, :string
    field :actor_id, :string
    field :event_type, :string
    field :event_name, :string
    field :event_name_prefix, :string

    belongs_to :target, Target,
      references: :key,
      foreign_key: :target_key,
      type: :string,
      define_field: true

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :key,
      :name,
      :priority,
      :signal_pattern,
      :adapter,
      :channel_id,
      :scope_id,
      :thread_id,
      :actor_id,
      :event_type,
      :event_name,
      :event_name_prefix,
      :target_key
    ])
    |> validate_required([:key, :name, :priority, :signal_pattern, :target_key])
    |> validate_format(:key, ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,128}$/)
    |> validate_format(:signal_pattern, ~r/^[a-zA-Z0-9.*_-]+(\.[a-zA-Z0-9.*_-]+)*$/)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_event_name_shape()
    |> foreign_key_constraint(:target_key)
    |> check_constraint(:priority, name: :runtime_inbound_routes_priority_range)
    |> check_constraint(:event_name, name: :runtime_inbound_routes_event_name_exclusive)
  end

  defp validate_event_name_shape(changeset) do
    case {get_field(changeset, :event_name), get_field(changeset, :event_name_prefix)} do
      {name, prefix} when is_binary(name) and is_binary(prefix) ->
        add_error(changeset, :event_name_prefix, "cannot be set when event_name is set")

      _ ->
        changeset
    end
  end
end
