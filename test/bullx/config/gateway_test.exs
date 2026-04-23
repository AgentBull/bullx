defmodule BullX.Config.GatewayTest do
  use ExUnit.Case, async: false

  alias BullX.Config.Gateway

  setup do
    previous = Application.get_env(:bullx, :gateway)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bullx, :gateway)
        value -> Application.put_env(:bullx, :gateway, value)
      end
    end)

    :ok
  end

  test "reads boot/static gateway config through BullX.Config" do
    adapter_spec = {{:example, "default"}, __MODULE__, %{dedupe_ttl_ms: 123}}

    Application.put_env(:bullx, :gateway,
      adapters: [adapter_spec],
      gating: [gaters: [__MODULE__]],
      moderation: [moderators: [__MODULE__]],
      security: [adapter: __MODULE__],
      policy_timeout_fallback: :allow_with_flag,
      policy_error_fallback: :deny
    )

    assert Gateway.adapters() == [adapter_spec]

    assert Gateway.config() == [
             adapters: [adapter_spec],
             gating: [gaters: [__MODULE__]],
             moderation: [moderators: [__MODULE__]],
             security: [adapter: __MODULE__],
             policy_timeout_fallback: :allow_with_flag,
             policy_error_fallback: :deny
           ]
  end
end
