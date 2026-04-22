defmodule BullXGateway.PublishInboundTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BullXGateway, as: Gateway
  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.ControlPlane.DedupeSeen
  alias BullXGateway.ControlPlane.TriggerRecord
  alias BullXGateway.DedupeKey
  alias BullXGateway.Inputs.Trigger
  alias BullXGateway.Signals.InboundReceived
  alias BullX.Repo
  alias Jido.Signal.Bus

  defmodule ExplodingGater do
    @behaviour BullXGateway.Gating

    @impl true
    def check(_ctx, _opts), do: raise("boom")
  end

  defmodule RedactModerator do
    @behaviour BullXGateway.Moderation

    @impl true
    def moderate(signal, _opts) do
      {:modify, %{signal | data: Map.put(signal.data, "agent_text", "redacted")}}
    end
  end

  defmodule AtomChannelGater do
    @behaviour BullXGateway.Gating

    @impl true
    def check(%BullXGateway.SignalContext{channel: {:github, _tenant}}, _opts), do: :allow
    def check(_ctx, _opts), do: {:deny, :wrong_channel, "expected github atom channel"}
  end

  defmodule DenySecurity do
    @behaviour BullXGateway.Security

    @impl true
    def verify_sender(_channel, _input, _opts), do: {:deny, :forbidden, "blocked"}

    @impl true
    def sanitize_outbound(_channel, delivery, _opts), do: {:ok, delivery}
  end

  defmodule DenyGater do
    @behaviour BullXGateway.Gating

    @impl true
    def check(_ctx, _opts), do: {:deny, :not_allowed, "blocked by gater"}
  end

  defmodule FlagModerator do
    @behaviour BullXGateway.Moderation

    @impl true
    def moderate(_signal, _opts), do: {:flag, :suspect, "needs review"}
  end

  defmodule RejectModerator do
    @behaviour BullXGateway.Moderation

    @impl true
    def moderate(_signal, _opts), do: {:reject, :bad_content, "blocked by moderator"}
  end

  defmodule PublishedDuplicateStore do
    @behaviour BullXGateway.ControlPlane.Store

    @state __MODULE__.State

    def put_state(state) do
      Agent.update(@state, fn _ -> state end)
    end

    def state do
      Agent.get(@state, & &1)
    end

    @impl true
    def transaction(fun) do
      case fun.(__MODULE__) do
        {:error, reason} -> {:error, reason}
        other -> {:ok, other}
      end
    end

    @impl true
    def put_trigger_record(_attrs), do: {:error, :duplicate}

    @impl true
    def fetch_trigger_record_by_dedupe_key(dedupe_key) do
      %{record: record} = state()

      case record.dedupe_key == dedupe_key do
        true -> {:ok, record}
        false -> :error
      end
    end

    @impl true
    def list_trigger_records(_filters), do: {:ok, []}

    @impl true
    def update_trigger_record(id, changes) do
      Agent.update(@state, fn %{record: record} = state ->
        %{state | record: Map.merge(record, Map.new(changes))}
      end)

      send_update(id, changes)
      :ok
    end

    @impl true
    def put_dedupe_seen(attrs) do
      Agent.update(@state, fn state -> %{state | dedupe_seen: attrs} end)
      :ok
    end

    @impl true
    def fetch_dedupe_seen(_dedupe_key), do: :error

    @impl true
    def list_active_dedupe_seen, do: {:ok, []}

    @impl true
    def delete_expired_dedupe_seen, do: {:ok, 0}

    @impl true
    def delete_old_trigger_records(_before), do: {:ok, 0}

    @impl true
    def put_dispatch(_attrs), do: {:error, :not_implemented}

    @impl true
    def update_dispatch(_id, _changes), do: {:error, :not_implemented}

    @impl true
    def delete_dispatch(_id), do: {:error, :not_implemented}

    @impl true
    def fetch_dispatch(_id), do: :error

    @impl true
    def list_dispatches_by_scope(_channel, _scope_id, _statuses), do: {:ok, []}

    @impl true
    def put_attempt(_attrs), do: {:error, :not_implemented}

    @impl true
    def list_attempts(_dispatch_id), do: {:ok, []}

    @impl true
    def put_dead_letter(_attrs), do: {:error, :not_implemented}

    @impl true
    def fetch_dead_letter(_dispatch_id), do: :error

    @impl true
    def list_dead_letters(_filters), do: {:ok, []}

    @impl true
    def increment_dead_letter_replay_count(_dispatch_id), do: {:error, :not_implemented}

    defp send_update(id, changes) do
      case state() do
        %{test_pid: test_pid} when is_pid(test_pid) ->
          send(test_pid, {:store_updated, id, changes})

        _ ->
          :ok
      end
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BullX.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    for pid <- [
          Process.whereis(BullXGateway.ControlPlane),
          Process.whereis(BullXGateway.ControlPlane.InboundReplay),
          Process.whereis(BullXGateway.Retention)
        ],
        is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, pid)
    end

    :ok = BullXGateway.Deduper.clear()
    :ok
  end

  test "publishes an inbound trigger, stores it, and dedupes repeats" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-1")

    assert {:ok, :published} = Gateway.publish_inbound(input)
    assert_receive {:signal, signal}, 500
    assert signal.id == "evt-1"
    assert signal.data["event_category"] == "trigger"

    dedupe_key = DedupeKey.generate(input.source, input.id)
    assert {:ok, record} = ControlPlane.fetch_trigger_record_by_dedupe_key(dedupe_key)
    assert %DateTime{} = record.published_at

    assert {:ok, :duplicate} = Gateway.publish_inbound(input)
    refute_receive {:signal, _signal}, 100
  end

  test "expired dedupe row allows the same source/id to publish again" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-ttl")

    assert {:ok, :published} = Gateway.publish_inbound(input)
    assert_receive {:signal, _signal}, 500

    dedupe_key = DedupeKey.generate(input.source, input.id)
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(
      from(d in DedupeSeen, where: d.dedupe_key == ^dedupe_key),
      set: [expires_at: past]
    )

    :ok = BullXGateway.Deduper.clear()

    assert {:ok, :published} = Gateway.publish_inbound(input)
    assert_receive {:signal, replayed_signal}, 500
    assert replayed_signal.id == input.id
  end

  test "replays unpublished trigger records from the control plane" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-replay")
    {:ok, signal} = InboundReceived.new(input)
    dedupe_key = DedupeKey.generate(signal.source, signal.id)

    record = %{
      source: signal.source,
      external_id: signal.id,
      dedupe_key: dedupe_key,
      signal_id: signal.id,
      signal_type: signal.type,
      event_category: signal.data["event_category"],
      duplex: signal.data["duplex"],
      channel_adapter: signal.extensions["bullx_channel_adapter"],
      channel_tenant: signal.extensions["bullx_channel_tenant"],
      scope_id: signal.data["scope_id"],
      thread_id: signal.data["thread_id"],
      signal_envelope: signal_map(signal),
      policy_outcome: "published"
    }

    assert {:ok, :ok} = ControlPlane.transaction(fn store -> store.put_trigger_record(record) end)

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(from(t in TriggerRecord, where: t.dedupe_key == ^dedupe_key),
      set: [inserted_at: past]
    )

    BullXGateway.ControlPlane.InboundReplay.run_once()

    assert_receive {:signal, replayed_signal}, 500
    assert replayed_signal.id == signal.id

    assert {:ok, stored_record} = ControlPlane.fetch_trigger_record_by_dedupe_key(dedupe_key)
    assert %DateTime{} = stored_record.published_at
  end

  test "run_once replays a freshly failed pending record without waiting for the grace window" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-run-once-now")
    {:ok, signal} = InboundReceived.new(input)
    dedupe_key = DedupeKey.generate(signal.source, signal.id)

    record = %{
      source: signal.source,
      external_id: signal.id,
      dedupe_key: dedupe_key,
      signal_id: signal.id,
      signal_type: signal.type,
      event_category: signal.data["event_category"],
      duplex: signal.data["duplex"],
      channel_adapter: signal.extensions["bullx_channel_adapter"],
      channel_tenant: signal.extensions["bullx_channel_tenant"],
      scope_id: signal.data["scope_id"],
      thread_id: signal.data["thread_id"],
      signal_envelope: signal_map(signal),
      policy_outcome: "published"
    }

    assert {:ok, :ok} = ControlPlane.transaction(fn store -> store.put_trigger_record(record) end)

    BullXGateway.ControlPlane.InboundReplay.run_once()

    assert_receive {:signal, replayed_signal}, 500
    assert replayed_signal.id == signal.id

    assert {:ok, stored_record} = ControlPlane.fetch_trigger_record_by_dedupe_key(dedupe_key)
    assert %DateTime{} = stored_record.published_at
  end

  test "gating fallback flags and moderation modifications are reflected in the published signal" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-policy")

    opts = [
      gating: [gaters: [ExplodingGater]],
      moderation: [moderators: [RedactModerator]],
      policy_error_fallback: :allow_with_flag
    ]

    assert {:ok, :published} = Gateway.publish_inbound(input, opts)
    assert_receive {:signal, signal}, 500
    assert signal.data["agent_text"] == "redacted"
    assert signal.extensions["bullx_moderation_modified"] == true

    assert [
             %{
               "stage" => "gating",
               "reason" => "error_fallback"
             }
           ] = signal.extensions["bullx_flags"]
  end

  test "security denials stop the signal before publish" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-security")

    assert {:error, {:security_denied, :verify, :forbidden, "blocked"}} =
             Gateway.publish_inbound(input, security: [adapter: DenySecurity])

    refute_receive {:signal, _signal}, 100
  end

  test "unpublished trigger records have no dedupe_seen row; replay writes it" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-no-mark-seen")
    {:ok, signal} = InboundReceived.new(input)
    dedupe_key = DedupeKey.generate(signal.source, signal.id)

    record = %{
      source: signal.source,
      external_id: signal.id,
      dedupe_key: dedupe_key,
      signal_id: signal.id,
      signal_type: signal.type,
      event_category: signal.data["event_category"],
      duplex: signal.data["duplex"],
      channel_adapter: signal.extensions["bullx_channel_adapter"],
      channel_tenant: signal.extensions["bullx_channel_tenant"],
      scope_id: signal.data["scope_id"],
      thread_id: signal.data["thread_id"],
      signal_envelope: signal_map(signal),
      policy_outcome: "published"
    }

    assert {:ok, :ok} = ControlPlane.transaction(fn store -> store.put_trigger_record(record) end)

    # Invariant: no dedupe_seen row exists while record is unpublished.
    assert :error = ControlPlane.fetch_dedupe_seen(dedupe_key)

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(from(t in TriggerRecord, where: t.dedupe_key == ^dedupe_key),
      set: [inserted_at: past]
    )

    BullXGateway.ControlPlane.InboundReplay.run_once()
    assert_receive {:signal, _}, 500

    # After replay, dedupe_seen is recorded.
    assert {:ok, _} = ControlPlane.fetch_dedupe_seen(dedupe_key)
  end

  test "dedupe TTL is read per-adapter from AdapterRegistry" do
    short_tenant = unique_tenant()
    long_tenant = unique_tenant()
    short_ttl = 50
    long_ttl = 86_400_000

    register_adapter({:github, short_tenant}, short_ttl)
    register_adapter({:github, long_tenant}, long_ttl)
    subscribe_inbound!()

    short_input = trigger_input(short_tenant, "evt-ttl-short")
    long_input = trigger_input(long_tenant, "evt-ttl-long")

    assert {:ok, :published} = Gateway.publish_inbound(short_input)
    assert {:ok, :published} = Gateway.publish_inbound(long_input)
    assert_receive {:signal, _}, 500
    assert_receive {:signal, _}, 500

    short_key = DedupeKey.generate(short_input.source, short_input.id)
    long_key = DedupeKey.generate(long_input.source, long_input.id)

    {:ok, short_row} = ControlPlane.fetch_dedupe_seen(short_key)
    {:ok, long_row} = ControlPlane.fetch_dedupe_seen(long_key)

    assert DateTime.diff(short_row.expires_at, short_row.seen_at, :millisecond) == short_ttl
    assert DateTime.diff(long_row.expires_at, long_row.seen_at, :millisecond) == long_ttl
  end

  test "gater :deny halts the pipeline and leaves no dedupe record" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-gater-deny")

    assert {:error, {:policy_denied, :gating, :not_allowed, "blocked by gater"}} =
             Gateway.publish_inbound(input, gating: [gaters: [DenyGater]])

    refute_receive {:signal, _signal}, 100

    dedupe_key = DedupeKey.generate(input.source, input.id)
    assert :error = ControlPlane.fetch_dedupe_seen(dedupe_key)

    # A second attempt still re-runs the pipeline (not short-circuited as duplicate).
    assert {:error, {:policy_denied, :gating, _, _}} =
             Gateway.publish_inbound(input, gating: [gaters: [DenyGater]])
  end

  test "gaters can match SignalContext.channel as an atom tuple" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-atom-channel")

    assert {:ok, :published} =
             Gateway.publish_inbound(input, gating: [gaters: [AtomChannelGater]])

    assert_receive {:signal, signal}, 500
    assert signal.id == input.id
  end

  test "moderator :reject halts the pipeline" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-moderator-reject")

    assert {:error, {:policy_denied, :moderation, :bad_content, "blocked by moderator"}} =
             Gateway.publish_inbound(input, moderation: [moderators: [RejectModerator]])

    refute_receive {:signal, _signal}, 100
  end

  test "moderator :flag accumulates into bullx_flags without halting" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(tenant, "evt-moderator-flag")

    assert {:ok, :published} =
             Gateway.publish_inbound(input, moderation: [moderators: [FlagModerator]])

    assert_receive {:signal, signal}, 500

    assert [
             %{
               "stage" => "moderation",
               "reason" => "suspect",
               "description" => "needs review"
             }
           ] = signal.extensions["bullx_flags"]
  end

  test "security denial short-circuits before gating telemetry fires" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    handler_id = "test-gating-short-circuit-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:bullx, :gateway, :gating, :decision],
      fn _event, _m, _meta, _cfg -> send(test_pid, :gating_fired) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    input = trigger_input(tenant, "evt-short-circuit")

    assert {:error, {:security_denied, :verify, :forbidden, "blocked"}} =
             Gateway.publish_inbound(input,
               security: [adapter: DenySecurity],
               gating: [gaters: [DenyGater]]
             )

    refute_receive :gating_fired, 100
  end

  test "telemetry spans use the RFC namespace" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)

    handler_id = "test-publish-stop-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:bullx, :gateway, :publish_inbound, :stop],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:publish_stop, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, :published} =
             Gateway.publish_inbound(trigger_input(tenant, "evt-telemetry-stop"))

    assert_receive {:publish_stop, %{policy_outcome: :published}}, 500
  end

  test "already-published duplicate records return duplicate without republishing" do
    tenant = unique_tenant()
    register_adapter({:github, tenant}, 86_400_000)
    subscribe_inbound!()

    {:ok, _agent} =
      start_supervised(%{
        id: PublishedDuplicateStore.State,
        start:
          {Agent, :start_link,
           [
             fn -> %{record: nil, dedupe_seen: nil, test_pid: self()} end,
             [name: PublishedDuplicateStore.State]
           ]}
      })

    input = trigger_input(tenant, "evt-published-duplicate")
    {:ok, signal} = InboundReceived.new(input)
    dedupe_key = DedupeKey.generate(signal.source, signal.id)

    PublishedDuplicateStore.put_state(%{
      test_pid: self(),
      dedupe_seen: nil,
      record: %{
        id: Ecto.UUID.generate(),
        source: signal.source,
        external_id: signal.id,
        dedupe_key: dedupe_key,
        signal_id: signal.id,
        signal_type: signal.type,
        event_category: signal.data["event_category"],
        duplex: signal.data["duplex"],
        channel_adapter: signal.extensions["bullx_channel_adapter"],
        channel_tenant: signal.extensions["bullx_channel_tenant"],
        scope_id: signal.data["scope_id"],
        thread_id: signal.data["thread_id"],
        signal_envelope: signal_map(signal),
        policy_outcome: "published",
        published_at: DateTime.utc_now(),
        inserted_at: DateTime.utc_now()
      }
    })

    original_state = :sys.get_state(BullXGateway.ControlPlane)

    on_exit(fn ->
      :sys.replace_state(BullXGateway.ControlPlane, fn _ -> original_state end)
    end)

    :sys.replace_state(BullXGateway.ControlPlane, fn state ->
      %{state | store: PublishedDuplicateStore}
    end)

    assert {:ok, :duplicate} = Gateway.publish_inbound(input)
    refute_receive {:signal, _signal}, 100
    refute_receive {:store_updated, _, _}, 100

    assert %{dedupe_seen: %{external_id: external_id}} = PublishedDuplicateStore.state()
    assert external_id == signal.id
  end

  defp register_adapter(channel, dedupe_ttl_ms) do
    AdapterRegistry.register(channel, __MODULE__, %{dedupe_ttl_ms: dedupe_ttl_ms})
  end

  defp subscribe_inbound! do
    {:ok, subscription_id} =
      Bus.subscribe(
        BullXGateway.SignalBus,
        "com.agentbull.x.inbound.**",
        dispatch: {:pid, target: self()}
      )

    on_exit(fn -> Bus.unsubscribe(BullXGateway.SignalBus, subscription_id) end)
  end

  defp trigger_input(tenant, event_id) do
    %Trigger{
      id: event_id,
      source: "bullx://gateway/github/#{tenant}",
      channel: {:github, tenant},
      scope_id: "bullx/example",
      thread_id: nil,
      actor: %{
        id: "github:octocat",
        display: "octocat",
        bot: false,
        app_user_id: nil
      },
      agent_text: "Issue opened",
      adapter_event: %{
        type: "github.issue.opened",
        version: 1,
        data: %{issue_number: 101}
      },
      refs: [
        %{kind: "issue", id: "101", url: "https://github.com/example/issues/101"}
      ],
      content: []
    }
  end

  defp signal_map(signal) do
    signal
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp unique_tenant do
    "tenant_#{System.unique_integer([:positive])}"
  end
end
