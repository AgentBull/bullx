defmodule BullX.Config.ReqLLMBridgeTest do
  use BullX.DataCase, async: false

  alias BullX.Config.ReqLLM
  alias BullX.Config.ReqLLM.BootSync
  alias BullX.Config.ReqLLM.Bridge

  @bridge_config_keys [
    "bullx.req_llm.receive_timeout_ms",
    "bullx.req_llm.metadata_timeout_ms",
    "bullx.req_llm.stream_completion_cleanup_after_ms",
    "bullx.req_llm.debug",
    "bullx.req_llm.redact_context"
  ]

  @out_of_scope_config_keys [
    "bullx.req_llm.anthropic_api_key",
    "bullx.req_llm.custom_providers",
    "bullx.req_llm.load_dotenv"
  ]

  @bridge_app_env_keys [
    :receive_timeout,
    :metadata_timeout,
    :stream_completion_cleanup_after,
    :debug,
    :redact_context
  ]

  @out_of_scope_app_env_keys [
    :anthropic_api_key,
    :custom_providers,
    :load_dotenv
  ]

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    app_env = snapshot_app_env(@bridge_app_env_keys ++ @out_of_scope_app_env_keys)

    Enum.each(@bridge_config_keys ++ @out_of_scope_config_keys, &BullX.Config.Cache.delete_raw/1)
    Enum.each(@bridge_app_env_keys, &Application.delete_env(:req_llm, &1))
    Application.delete_env(:req_llm, :anthropic_api_key)
    Application.delete_env(:req_llm, :custom_providers)

    on_exit(fn ->
      restore_app_env(app_env)
      BullX.Config.Cache.refresh_all()
    end)

    :ok
  end

  test "put/2 synchronously bridges receive_timeout_ms" do
    assert :ok = BullX.Config.put("bullx.req_llm.receive_timeout_ms", "12345")

    assert Application.get_env(:req_llm, :receive_timeout) == 12_345
  end

  test "put/2 synchronously bridges debug" do
    assert :ok = BullX.Config.put("bullx.req_llm.debug", "true")

    assert Application.get_env(:req_llm, :debug) == true
  end

  test "delete/1 synchronously restores bridged defaults" do
    assert :ok = BullX.Config.put("bullx.req_llm.receive_timeout_ms", "12345")
    assert Application.get_env(:req_llm, :receive_timeout) == 12_345

    assert :ok = BullX.Config.delete("bullx.req_llm.receive_timeout_ms")

    assert Application.get_env(:req_llm, :receive_timeout) == ReqLLM.receive_timeout_ms!()
  end

  test "sync_all!/0 pushes every declared bridge key" do
    assert :ok = Bridge.sync_all!()

    req_llm_env = Application.get_all_env(:req_llm)

    Enum.each(ReqLLM.bridge_keyspec(), fn {key, _fun} ->
      assert Keyword.has_key?(req_llm_env, key)
    end)
  end

  test "BootSync runs synchronously and returns ignore" do
    Application.put_env(:req_llm, :receive_timeout, :stale)

    assert :ignore = BootSync.start_link([])

    assert Application.get_env(:req_llm, :receive_timeout) == ReqLLM.receive_timeout_ms!()
  end

  test "application-start and provider-specific req_llm keys are not bridged" do
    assert Application.get_env(:req_llm, :load_dotenv) == false

    assert :ok = BullX.Config.put("bullx.req_llm.anthropic_api_key", "secret")
    assert :ok = BullX.Config.put("bullx.req_llm.custom_providers", "Example.Provider")
    assert :ok = BullX.Config.put("bullx.req_llm.load_dotenv", "true")

    assert Application.get_env(:req_llm, :anthropic_api_key) == nil
    assert Application.get_env(:req_llm, :custom_providers) == nil
    assert Application.get_env(:req_llm, :load_dotenv) == false
  end

  defp snapshot_app_env(keys) do
    Map.new(keys, fn key -> {key, Application.fetch_env(:req_llm, key)} end)
  end

  defp restore_app_env(app_env) do
    Enum.each(app_env, fn
      {key, {:ok, value}} -> Application.put_env(:req_llm, key, value)
      {key, :error} -> Application.delete_env(:req_llm, key)
    end)
  end
end
