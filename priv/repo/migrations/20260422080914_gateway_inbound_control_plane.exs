defmodule BullX.Repo.Migrations.GatewayInboundControlPlane do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNLOGGED TABLE gateway_dedupe_seen (
      dedupe_key text PRIMARY KEY,
      source text NOT NULL,
      external_id text NOT NULL,
      expires_at timestamptz NOT NULL,
      seen_at timestamptz NOT NULL
    )
    """)

    execute("""
    CREATE INDEX gateway_dedupe_seen_expires_at_index
    ON gateway_dedupe_seen (expires_at)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS gateway_dedupe_seen")
  end
end
