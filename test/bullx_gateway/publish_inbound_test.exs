defmodule BullXGateway.PublishInboundTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BullXGateway, as: Gateway
  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.ControlPlane.DedupeSeen
  alias BullXGateway.DedupeKey
  alias BullXGateway.Inputs.Trigger
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
      {:modify,
       %{
         signal
         | data:
             Map.put(signal.data, "content", [
               %{"kind" => "text", "body" => %{"text" => "redacted"}}
             ])
       }}
    end
  end

  defmodule AtomChannelGater do
    @behaviour BullXGateway.Gating

    @impl true
    def check(%BullXGateway.SignalContext{channel: {:github, _channel_id}}, _opts), do: :allow
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

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BullX.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    for pid <- [
          Process.whereis(BullXGateway.ControlPlane),
          Process.whereis(BullXGateway.Retention)
        ],
        is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, pid)
    end

    :ok = BullXGateway.Deduper.clear()
    :ok
  end

  test "publishes an inbound trigger, dedupes repeats after Bus.publish succeeds" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-1")

    assert {:ok, :published} = Gateway.publish_inbound(input)
    assert_receive {:signal, signal}, 500
    assert signal.id == "evt-1"
    assert get_in(signal.data, ["event", "type"]) == "trigger"

    dedupe_key = DedupeKey.generate(input.source, input.id)
    assert {:ok, _} = ControlPlane.fetch_dedupe_seen(dedupe_key)

    assert {:ok, :duplicate} = Gateway.publish_inbound(input)
    refute_receive {:signal, _signal}, 100
  end

  test "expired dedupe row allows the same source/id to publish again" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-ttl")

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

  test "gating fallback flags and moderation modifications are reflected in the published signal" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-policy")

    opts = [
      gating: [gaters: [ExplodingGater]],
      moderation: [moderators: [RedactModerator]],
      policy_error_fallback: :allow_with_flag
    ]

    assert {:ok, :published} = Gateway.publish_inbound(input, opts)
    assert_receive {:signal, signal}, 500
    assert signal.data["content"] == [%{"kind" => "text", "body" => %{"text" => "redacted"}}]
    assert signal.extensions["bullx_moderation_modified"] == true

    assert [
             %{
               "stage" => "gating",
               "reason" => "error_fallback"
             }
           ] = signal.extensions["bullx_flags"]
  end

  test "security denials stop the signal before publish" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-security")

    assert {:error, {:security_denied, :verify, :forbidden, "blocked"}} =
             Gateway.publish_inbound(input, security: [adapter: DenySecurity])

    refute_receive {:signal, _signal}, 100
  end

  test "dedupe TTL is read per-adapter from AdapterRegistry" do
    short_channel_id = unique_channel_id()
    long_channel_id = unique_channel_id()
    short_ttl = 50
    long_ttl = 86_400_000

    register_adapter({:github, short_channel_id}, short_ttl)
    register_adapter({:github, long_channel_id}, long_ttl)
    subscribe_inbound!()

    short_input = trigger_input(short_channel_id, "evt-ttl-short")
    long_input = trigger_input(long_channel_id, "evt-ttl-long")

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
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-gater-deny")

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
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-atom-channel")

    assert {:ok, :published} =
             Gateway.publish_inbound(input, gating: [gaters: [AtomChannelGater]])

    assert_receive {:signal, signal}, 500
    assert signal.id == input.id
  end

  test "moderator :reject halts the pipeline" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-moderator-reject")

    assert {:error, {:policy_denied, :moderation, :bad_content, "blocked by moderator"}} =
             Gateway.publish_inbound(input, moderation: [moderators: [RejectModerator]])

    refute_receive {:signal, _signal}, 100
  end

  test "moderator :flag accumulates into bullx_flags without halting" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    input = trigger_input(channel_id, "evt-moderator-flag")

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

  test "security denial yields policy_outcome :denied_security on publish_inbound:stop" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)
    subscribe_inbound!()

    handler_id = "test-publish-stop-denied-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:bullx, :gateway, :publish_inbound, :stop],
      fn _event, _m, metadata, _cfg -> send(test_pid, {:publish_stop, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    input = trigger_input(channel_id, "evt-short-circuit")

    assert {:error, {:security_denied, :verify, :forbidden, "blocked"}} =
             Gateway.publish_inbound(input,
               security: [adapter: DenySecurity],
               gating: [gaters: [DenyGater]]
             )

    assert_receive {:publish_stop, %{policy_outcome: :denied_security}}, 500
  end

  test "telemetry spans use the RFC namespace" do
    channel_id = unique_channel_id()
    register_adapter({:github, channel_id}, 86_400_000)

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
             Gateway.publish_inbound(trigger_input(channel_id, "evt-telemetry-stop"))

    assert_receive {:publish_stop, %{policy_outcome: :published}}, 500
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

  defp trigger_input(channel_id, event_id) do
    %Trigger{
      id: event_id,
      source: "bullx://gateway/github/#{channel_id}",
      channel: {:github, channel_id},
      scope_id: "bullx/example",
      thread_id: nil,
      actor: %{
        id: "github:octocat",
        display: "octocat",
        bot: false
      },
      content: [
        %{kind: :text, body: %{"text" => "Issue opened"}}
      ],
      event: %{
        name: "github.issue.opened",
        version: 1,
        data: %{issue_number: 101}
      },
      refs: [
        %{kind: "issue", id: "101", url: "https://github.com/example/issues/101"}
      ]
    }
  end

  defp unique_channel_id do
    "channel_#{System.unique_integer([:positive])}"
  end
end
