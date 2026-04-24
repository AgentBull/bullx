defmodule BullX.Repo.Migrations.CreateAccountsAuthnTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE user_status AS ENUM ('active', 'banned')",
      "DROP TYPE user_status"
    )

    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :username, :text
      add :email, :text
      add :phone, :text
      add :display_name, :text, null: false
      add :avatar_url, :text
      add :status, :user_status, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:username], where: "username IS NOT NULL")
    create unique_index(:users, [:email], where: "email IS NOT NULL")
    create unique_index(:users, [:phone], where: "phone IS NOT NULL")

    create table(:user_channel_bindings, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      add :adapter, :text, null: false
      add :channel_id, :text, null: false
      add :external_id, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_channel_bindings, [:user_id])

    create unique_index(:user_channel_bindings, [:adapter, :channel_id, :external_id],
             name: :user_channel_bindings_actor_index
           )

    create table(:activation_codes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :code_hash, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :created_by_user_id, references(:users, type: :uuid, on_delete: :nilify_all)

      add :revoked_at, :utc_datetime_usec
      add :used_at, :utc_datetime_usec
      add :used_by_adapter, :text
      add :used_by_channel_id, :text
      add :used_by_external_id, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:activation_codes, [:code_hash])
    create index(:activation_codes, [:expires_at])
    create index(:activation_codes, [:created_by_user_id])

    create table(:user_channel_auth_codes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :code_hash, :text, null: false

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_channel_auth_codes, [:code_hash])
    create index(:user_channel_auth_codes, [:user_id])
    create index(:user_channel_auth_codes, [:inserted_at])
  end
end
