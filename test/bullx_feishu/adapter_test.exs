defmodule BullXFeishu.AdapterTest do
  use ExUnit.Case, async: true

  alias BullXFeishu.Adapter

  test "connectivity_check verifies self-built app credentials" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/open-apis/auth/v3/tenant_access_token/internal"

      Req.Test.json(conn, %{
        "code" => 0,
        "expire" => 7200,
        "tenant_access_token" => "tenant-token"
      })
    end)

    assert {:ok, result} =
             Adapter.connectivity_check({:feishu, "default"}, %{
               app_id: "cli_test",
               app_secret: "secret_test",
               req_options: [plug: {Req.Test, __MODULE__}]
             })

    assert result["adapter"] == "feishu"
    assert result["channel_id"] == "default"
    assert result["domain"] == "feishu"
    assert result["credential"]["status"] == "verified"
    assert result["transport"]["long_lived_client_started"] == false
  end

  test "connectivity_check maps Feishu credential errors without leaking secrets" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"code" => 99_991_663, "msg" => "invalid app credentials"})
    end)

    assert {:error, error} =
             Adapter.connectivity_check({:feishu, "default"}, %{
               app_id: "cli_test",
               app_secret: "secret_test",
               req_options: [plug: {Req.Test, __MODULE__}]
             })

    assert error["kind"] == "auth"
    assert error["message"] == "invalid app credentials"
    refute inspect(error) =~ "secret_test"
  end
end
