defmodule BullX.Repo.Migrations.GatewayOutboundDeliveryDlq do
  use Ecto.Migration

  def up do
    # In-flight outbound dispatches. UNLOGGED: terminal success deletes the
    # row, terminal failure writes `gateway_dead_letters` and deletes this
    # row. Only three statuses are valid: queued, running, retry_scheduled.
    execute("""
    CREATE UNLOGGED TABLE gateway_dispatches (
      id text PRIMARY KEY,
      op text NOT NULL,
      channel_adapter text NOT NULL,
      channel_tenant text NOT NULL,
      scope_id text NOT NULL,
      thread_id text,
      caused_by_signal_id text,
      payload jsonb NOT NULL,
      status text NOT NULL,
      attempts integer NOT NULL DEFAULT 0,
      max_attempts integer NOT NULL,
      available_at timestamptz,
      last_error jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX gateway_dispatches_status_available_index
    ON gateway_dispatches (status, available_at)
    """)

    execute("""
    CREATE INDEX gateway_dispatches_scope_index
    ON gateway_dispatches (channel_adapter, channel_tenant, scope_id, status, inserted_at)
    """)

    # Per-attempt adapter invocation records. UNLOGGED: used for 7-day debug
    # history, not durable. id is "#{dispatch_id}:#{attempt}" and is upserted
    # (running -> completed/failed).
    execute("""
    CREATE UNLOGGED TABLE gateway_attempts (
      id text PRIMARY KEY,
      dispatch_id text NOT NULL,
      attempt integer NOT NULL,
      started_at timestamptz NOT NULL,
      finished_at timestamptz,
      status text NOT NULL,
      outcome jsonb,
      error jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE INDEX gateway_attempts_dispatch_index
    ON gateway_attempts (dispatch_id, attempt)
    """)

    execute("""
    CREATE INDEX gateway_attempts_inserted_at_index
    ON gateway_attempts (inserted_at)
    """)

    # Terminal outbound failures. LOGGED: the single outbound table that
    # survives a Postgres server crash. Evidence of "Gateway gave up".
    create table(:gateway_dead_letters, primary_key: false) do
      add :dispatch_id, :text, primary_key: true
      add :op, :text, null: false
      add :channel_adapter, :text, null: false
      add :channel_tenant, :text, null: false
      add :scope_id, :text, null: false
      add :thread_id, :text
      add :caused_by_signal_id, :text
      add :payload, :map, null: false
      add :final_error, :map, null: false
      add :attempts_total, :integer, null: false
      add :attempts_summary, :map
      add :dead_lettered_at, :utc_datetime_usec, null: false
      add :replay_count, :integer, null: false, default: 0
      add :archived_at, :utc_datetime_usec
    end

    create index(
             :gateway_dead_letters,
             [:channel_adapter, :channel_tenant, :scope_id, :dead_lettered_at]
           )

    execute("""
    CREATE INDEX gateway_dead_letters_active_index
    ON gateway_dead_letters (dead_lettered_at DESC)
    WHERE archived_at IS NULL
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS gateway_dead_letters")
    execute("DROP TABLE IF EXISTS gateway_attempts")
    execute("DROP TABLE IF EXISTS gateway_dispatches")
  end
end
