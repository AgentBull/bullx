defmodule BullX.Repo.Migrations.CreateAccountsAuthzTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE user_group_type AS ENUM ('static', 'computed')",
      "DROP TYPE user_group_type"
    )

    create table(:user_groups, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :type, :user_group_type, null: false
      add :description, :text
      add :computed_expression, :jsonb
      add :built_in, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_groups, [:name])

    create constraint(:user_groups, :user_groups_name_present, check: "length(btrim(name)) > 0")

    create constraint(:user_groups, :user_groups_expression_matches_type,
             check: """
             (type = 'static' AND computed_expression IS NULL)
             OR (type = 'computed' AND computed_expression IS NOT NULL)
             """
           )

    create table(:user_group_memberships, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :group_id, references(:user_groups, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_group_memberships, [:group_id])

    create table(:permission_grants, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :group_id, references(:user_groups, type: :uuid, on_delete: :delete_all)
      add :resource_pattern, :text, null: false
      add :action, :text, null: false
      add :condition, :text, null: false, default: "true"
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:permission_grants, :permission_grants_principal_exclusive,
             check: """
             (user_id IS NOT NULL AND group_id IS NULL)
             OR (user_id IS NULL AND group_id IS NOT NULL)
             """
           )

    create constraint(:permission_grants, :permission_grants_resource_pattern_wildcards,
             check: "(length(resource_pattern) - length(replace(resource_pattern, '*', ''))) <= 1"
           )

    create constraint(:permission_grants, :permission_grants_action_no_colon,
             check: "position(':' in action) = 0"
           )

    create constraint(:permission_grants, :permission_grants_resource_pattern_present,
             check: "length(resource_pattern) > 0"
           )

    create constraint(:permission_grants, :permission_grants_action_present,
             check: "length(action) > 0"
           )

    create index(:permission_grants, [:user_id])
    create index(:permission_grants, [:group_id])
    create index(:permission_grants, [:action, :resource_pattern])
  end
end
