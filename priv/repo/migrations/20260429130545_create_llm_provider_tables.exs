defmodule BullX.Repo.Migrations.CreateLlmProviderTables do
  use Ecto.Migration

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :provider_id, :text, null: false
      add :model_id, :text, null: false
      add :base_url, :text
      add :encrypted_api_key, :text
      add :provider_options, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:name])

    create table(:llm_alias_bindings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :alias_name, :text, null: false
      add :target_kind, :text, null: false

      add :target_provider_id,
          references(:llm_providers, type: :uuid, on_delete: :restrict),
          null: true

      add :target_alias_name, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_alias_bindings, [:alias_name])

    create constraint(:llm_alias_bindings, :alias_name_in_set,
             check: "alias_name IN ('default', 'fast', 'heavy', 'compression')"
           )

    create constraint(:llm_alias_bindings, :target_kind_in_set,
             check: "target_kind IN ('provider', 'alias')"
           )

    create constraint(:llm_alias_bindings, :target_alias_name_in_set,
             check:
               "target_alias_name IS NULL OR target_alias_name IN ('default', 'fast', 'heavy', 'compression')"
           )

    create constraint(:llm_alias_bindings, :alias_binding_target_shape,
             check: """
             (
               target_kind = 'provider' AND
               target_provider_id IS NOT NULL AND
               target_alias_name IS NULL
             ) OR (
               target_kind = 'alias' AND
               target_provider_id IS NULL AND
               target_alias_name IS NOT NULL
             )
             """
           )

    create constraint(:llm_alias_bindings, :default_alias_must_target_provider,
             check: "alias_name <> 'default' OR target_kind = 'provider'"
           )
  end
end
