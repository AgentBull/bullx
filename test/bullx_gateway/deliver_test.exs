defmodule BullXGateway.DeliverTest do
  use ExUnit.Case, async: false

  alias BullXGateway, as: Gateway
  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias Jido.Signal.Bus

  defmodule RetryThenSuccessAdapter do
    @behaviour BullXGateway.Adapter

    @impl true
    def adapter_id, do: :retry_then_success

    @impl true
    def capabilities, do: [:send]

    @impl true
    def deliver(%Delivery{} = delivery, %{config: config}) do
      attempt =
        Agent.get_and_update(config.agent, fn current ->
          next = current + 1
          {next, next}
        end)

      send(config.test_pid, {:adapter_attempt, delivery.id, attempt})

      case attempt do
        1 -> {:error, network_error(attempt)}
        2 -> {:error, network_error(attempt)}
        _ -> {:ok, Outcome.new_success(delivery.id, :sent, external_message_ids: ["msg-3"])}
      end
    end

    defp network_error(attempt) do
      %{
        "kind" => "network",
        "message" => "temporary failure #{attempt}"
      }
    end
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

    :ok = BullXGateway.OutboundDeduper.clear()
    :ok
  end

  test "retryable delivery failures can succeed on the final allowed attempt" do
    channel = {:retry_then_success, unique_channel_id()}
    delivery_id = "delivery-#{System.unique_integer([:positive])}"
    {:ok, attempts} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(attempts), do: Agent.stop(attempts) end)

    AdapterRegistry.register(channel, RetryThenSuccessAdapter, %{
      agent: attempts,
      test_pid: self(),
      retry_policy: [max_attempts: 3, base_backoff_ms: 5, max_backoff_ms: 5]
    })

    subscribe_delivery!()

    assert {:ok, ^delivery_id} =
             Gateway.deliver(%Delivery{
               id: delivery_id,
               op: :send,
               channel: channel,
               scope_id: "scope-a",
               content: %Content{kind: :text, body: %{"text" => "hello"}}
             })

    assert_receive {:adapter_attempt, ^delivery_id, 1}, 500
    assert_receive {:adapter_attempt, ^delivery_id, 2}, 500
    assert_receive {:adapter_attempt, ^delivery_id, 3}, 500

    assert_receive {:signal, signal}, 500
    assert signal.type == "com.agentbull.x.delivery.succeeded"
    assert signal.data["delivery_id"] == delivery_id
    assert signal.data["status"] == "sent"

    assert_eventually_deduped(delivery_id)

    assert :error = ControlPlane.fetch_dead_letter(delivery_id)
  end

  defp subscribe_delivery! do
    {:ok, subscription_id} =
      Bus.subscribe(
        BullXGateway.SignalBus,
        "com.agentbull.x.delivery.**",
        dispatch: {:pid, target: self()}
      )

    on_exit(fn -> Bus.unsubscribe(BullXGateway.SignalBus, subscription_id) end)
  end

  defp unique_channel_id do
    "channel_#{System.unique_integer([:positive])}"
  end

  defp assert_eventually_deduped(delivery_id, attempts_left \\ 20)

  defp assert_eventually_deduped(delivery_id, attempts_left) when attempts_left > 0 do
    case BullXGateway.OutboundDeduper.seen?(delivery_id) do
      {:hit, %Outcome{delivery_id: ^delivery_id, status: :sent}} ->
        :ok

      :miss ->
        Process.sleep(10)
        assert_eventually_deduped(delivery_id, attempts_left - 1)
    end
  end

  defp assert_eventually_deduped(delivery_id, 0) do
    assert {:hit, %Outcome{delivery_id: ^delivery_id, status: :sent}} =
             BullXGateway.OutboundDeduper.seen?(delivery_id)
  end
end
