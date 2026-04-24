defmodule BullXFeishu.DeliveryTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias BullXFeishu.{Config, Delivery}
  alias FeishuOpenAPI.{Client, TokenStore}

  setup do
    if :ets.info(TokenStore.table()) == :undefined do
      :ets.new(TokenStore.table(), [:named_table, :public, :set])
    end

    client =
      FeishuOpenAPI.new("cli_test", "secret_test", req_options: [plug: {Req.Test, __MODULE__}])

    put_tenant_token(client)

    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        client: client,
        app_id: "cli_test",
        app_secret: "secret_test"
      })

    on_exit(fn -> delete_tenant_token(client) end)

    {:ok, config: config}
  end

  test "sends text messages through Feishu message create", %{config: config} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/open-apis/im/v1/messages"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["receive_id"] == "oc_1"
      assert decoded["msg_type"] == "text"
      assert Jason.decode!(decoded["content"]) == %{"text" => "hello"}

      Req.Test.json(conn, %{"code" => 0, "data" => %{"message_id" => "om_sent"}})
    end)

    delivery = %GatewayDelivery{
      id: "delivery_1",
      op: :send,
      channel: {:feishu, "default"},
      scope_id: "oc_1",
      content: %Content{kind: :text, body: %{"text" => "hello"}}
    }

    assert {:ok, %Outcome{status: :sent, primary_external_id: "om_sent"}} =
             Delivery.deliver(delivery, config)
  end

  test "degrades missing reply target to normal chat send", %{config: config} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

      case call do
        0 ->
          assert conn.request_path == "/open-apis/im/v1/messages/om_missing/reply"
          Req.Test.json(conn, %{"code" => 230_011, "msg" => "message withdrawn"})

        1 ->
          assert conn.request_path == "/open-apis/im/v1/messages"
          Req.Test.json(conn, %{"code" => 0, "data" => %{"message_id" => "om_fallback"}})
      end
    end)

    delivery = %GatewayDelivery{
      id: "delivery_2",
      op: :send,
      channel: {:feishu, "default"},
      scope_id: "oc_1",
      reply_to_external_id: "om_missing",
      content: %Content{kind: :text, body: %{"text" => "hello"}}
    }

    assert {:ok,
            %Outcome{
              status: :degraded,
              primary_external_id: "om_fallback",
              warnings: ["reply_target_missing_sent_to_scope"]
            }} = Delivery.deliver(delivery, config)
  end

  defp put_tenant_token(%Client{} = client) do
    :ets.insert(
      TokenStore.table(),
      {{:tenant, Client.cache_namespace(client), nil}, "t-token", :infinity}
    )
  end

  defp delete_tenant_token(%Client{} = client) do
    :ets.delete(TokenStore.table(), {:tenant, Client.cache_namespace(client), nil})
  end
end
