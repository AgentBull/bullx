defmodule BullX.Repo.Migrations.CreateRuntimeTargetTables do
  use Ecto.Migration

  def change do
    create table(:runtime_targets, primary_key: false) do
      add :key, :text, primary_key: true
      add :kind, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:runtime_targets, :runtime_targets_kind_identifier_shape,
             check: "kind ~ '^[a-z][a-z0-9_]*$'"
           )

    create constraint(:runtime_targets, :runtime_targets_config_json_object,
             check: "jsonb_typeof(config) = 'object'"
           )

    create constraint(:runtime_targets, :runtime_targets_main_kind,
             check: "key <> 'main' OR kind = 'agentic_chat_loop'"
           )

    create table(:runtime_inbound_routes, primary_key: false) do
      add :key, :text, primary_key: true
      add :name, :text, null: false
      add :priority, :integer, null: false, default: 0
      add :signal_pattern, :text, null: false, default: "com.agentbull.x.inbound.**"
      add :adapter, :text
      add :channel_id, :text
      add :scope_id, :text
      add :thread_id, :text
      add :actor_id, :text
      add :event_type, :text
      add :event_name, :text
      add :event_name_prefix, :text

      add :target_key,
          references(:runtime_targets, column: :key, type: :text, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runtime_inbound_routes, [:target_key])

    create constraint(:runtime_inbound_routes, :runtime_inbound_routes_priority_range,
             check: "priority >= 0 AND priority <= 100"
           )

    create constraint(:runtime_inbound_routes, :runtime_inbound_routes_event_name_exclusive,
             check: "event_name IS NULL OR event_name_prefix IS NULL"
           )
  end
end
