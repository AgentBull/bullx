defmodule BullXFeishu.ConfigTest do
  use ExUnit.Case, async: false

  alias BullXFeishu.Config

  setup do
    System.put_env("BULLX_TEST_FEISHU_APP_ID", "cli_test")
    System.put_env("BULLX_TEST_FEISHU_APP_SECRET", "secret_test")

    System.put_env(
      "BULLX_TEST_FEISHU_REDIRECT_URI",
      "https://bullx.test/sessions/feishu/callback"
    )

    on_exit(fn ->
      System.delete_env("BULLX_TEST_FEISHU_APP_ID")
      System.delete_env("BULLX_TEST_FEISHU_APP_SECRET")
      System.delete_env("BULLX_TEST_FEISHU_REDIRECT_URI")
    end)

    :ok
  end

  test "normalizes Feishu config and resolves system env indirection" do
    assert {:ok, config} =
             Config.normalize({:feishu, "default"}, %{
               app_id: {:system, "BULLX_TEST_FEISHU_APP_ID"},
               app_secret: {:system, "BULLX_TEST_FEISHU_APP_SECRET"},
               connection_mode: :webhook,
               dedupe_ttl_ms: 123,
               sso: %{
                 enabled: true,
                 redirect_uri: {:system, "BULLX_TEST_FEISHU_REDIRECT_URI"}
               }
             })

    assert config.channel == {:feishu, "default"}
    assert config.app_id == "cli_test"
    assert config.app_secret == "secret_test"
    assert config.connection_mode == :webhook
    assert config.dedupe_ttl_ms == 123
    assert config.sso.redirect_uri == "https://bullx.test/sessions/feishu/callback"
  end

  test "redacts secrets from exported config maps" do
    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        app_id: "cli_test",
        app_secret: "secret_test",
        verification_token: "verify",
        encrypt_key: "encrypt"
      })

    redacted = Config.redacted(config)

    refute Map.has_key?(redacted, :app_secret)
    assert redacted.verification_token == "[REDACTED]"
    assert redacted.encrypt_key == "[REDACTED]"
  end
end
