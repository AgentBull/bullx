defmodule BullX.Repo.Migrations.GatewayOutboundDeliveryDlq do
  use Ecto.Migration

  def up do
    execute("""
    CREATE UNLOGGED TABLE gateway_dead_letters (
      dispatch_id text PRIMARY KEY,
      op text NOT NULL,
      channel_adapter text NOT NULL,
      channel_id text NOT NULL,
      scope_id text NOT NULL,
      thread_id text,
      caused_by_signal_id text,
      payload jsonb NOT NULL,
      final_error jsonb NOT NULL,
      attempts_total integer NOT NULL,
      attempts_summary jsonb,
      dead_lettered_at timestamptz NOT NULL,
      replay_count integer NOT NULL DEFAULT 0
    )
    """)

    execute("""
    CREATE INDEX gateway_dead_letters_scope_index
    ON gateway_dead_letters (channel_adapter, channel_id, scope_id, dead_lettered_at)
    """)

    execute("""
    CREATE INDEX gateway_dead_letters_dead_lettered_at_index
    ON gateway_dead_letters (dead_lettered_at DESC)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS gateway_dead_letters")
  end
end
