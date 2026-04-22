defmodule BullX.Repo.Migrations.GatewayInboundControlPlane do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNLOGGED TABLE gateway_trigger_records (
      id uuid PRIMARY KEY,
      source text NOT NULL,
      external_id text NOT NULL,
      dedupe_key text NOT NULL,
      signal_id text NOT NULL,
      signal_type text NOT NULL,
      event_category text NOT NULL,
      duplex boolean NOT NULL,
      channel_adapter text NOT NULL,
      channel_tenant text NOT NULL,
      scope_id text NOT NULL,
      thread_id text,
      signal_envelope jsonb NOT NULL,
      policy_outcome text NOT NULL,
      published_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX gateway_trigger_records_dedupe_key_unpublished_index
    ON gateway_trigger_records (dedupe_key)
    WHERE published_at IS NULL
    """)

    execute("""
    CREATE INDEX gateway_trigger_records_scope_index
    ON gateway_trigger_records (channel_adapter, channel_tenant, scope_id, inserted_at DESC)
    """)

    execute("""
    CREATE INDEX gateway_trigger_records_pending_index
    ON gateway_trigger_records (published_at)
    WHERE published_at IS NULL
    """)

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
    execute("DROP TABLE IF EXISTS gateway_trigger_records")
  end
end
