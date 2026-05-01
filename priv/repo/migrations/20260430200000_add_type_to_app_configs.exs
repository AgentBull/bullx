defmodule BullX.Repo.Migrations.AddTypeToAppConfigs do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE app_config_type AS ENUM ('plain', 'secret')",
      "DROP TYPE app_config_type"
    )

    alter table(:app_configs) do
      add :type, :app_config_type, null: false, default: "plain"
    end
  end
end
