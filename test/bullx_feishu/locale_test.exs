defmodule BullXFeishu.LocaleTest do
  use ExUnit.Case, async: true

  @keys [
    "gateway.feishu.auth.activation_required",
    "gateway.feishu.auth.activation_success",
    "gateway.feishu.auth.activation_code_invalid",
    "gateway.feishu.auth.activation_failed",
    "gateway.feishu.auth.already_linked",
    "gateway.feishu.auth.auto_match_available",
    "gateway.feishu.auth.web_auth_created",
    "gateway.feishu.auth.web_auth_not_bound",
    "gateway.feishu.auth.web_auth_failed",
    "gateway.feishu.auth.login_not_bound",
    "gateway.feishu.auth.denied",
    "gateway.feishu.auth.direct_command_dm_only",
    "gateway.feishu.ping.pong",
    "gateway.feishu.delivery.fallback_text",
    "gateway.feishu.delivery.stream_generating",
    "gateway.feishu.delivery.stream_failed",
    "gateway.feishu.delivery.stream_cancelled",
    "gateway.feishu.delivery.reply_target_missing_sent_to_scope",
    "gateway.feishu.errors.unsupported_message",
    "gateway.feishu.errors.profile_unavailable"
  ]

  test "all Feishu adapter keys exist in bundled locales" do
    for locale <- [:"en-US", :"zh-Hans-CN"], key <- @keys do
      assert {:ok, text} =
               BullX.I18n.translate(key, %{code: "CODE", login_url: "https://bullx.test"},
                 locale: locale
               )

      refute text == key
    end
  end
end
