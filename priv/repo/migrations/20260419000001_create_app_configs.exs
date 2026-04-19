defmodule BullX.Repo.Migrations.CreateAppConfigs do
  use Ecto.Migration

  def change do
    create table(:app_configs, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :text, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
