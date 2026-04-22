defmodule BullX.Config.PrecedenceTest do
  use BullX.DataCase, async: false

  @db_key_integer "bullx.test_integer"
  @db_key_mode "bullx.test_mode"
  @db_key_custom "bullx.test_custom"
  @env_integer "BULLX_TEST_INTEGER"
  @env_mode "BULLX_TEST_MODE"
  @env_custom "BULLX_TEST_CUSTOM"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    on_exit(fn ->
      System.delete_env(@env_integer)
      System.delete_env(@env_mode)
      System.delete_env(@env_custom)
      BullX.Config.Cache.delete_raw(@db_key_integer)
      BullX.Config.Cache.delete_raw(@db_key_mode)
      BullX.Config.Cache.delete_raw(@db_key_custom)
    end)

    :ok
  end

  test "valid database override beats env and default" do
    insert_config!(@db_key_integer, "7")
    BullX.Config.Cache.refresh(@db_key_integer)
    System.put_env(@env_integer, "5")

    assert BullX.Config.TestSettings.test_integer!() == 7
  end

  test "malformed database override falls back to env" do
    insert_config!(@db_key_integer, "not_a_number")
    BullX.Config.Cache.refresh(@db_key_integer)
    System.put_env(@env_integer, "5")

    assert BullX.Config.TestSettings.test_integer!() == 5
  end

  test "Zoi-invalid database override falls back to env" do
    # 99 is outside Zoi range 1..20 for test_integer
    insert_config!(@db_key_integer, "99")
    BullX.Config.Cache.refresh(@db_key_integer)
    System.put_env(@env_integer, "5")

    assert BullX.Config.TestSettings.test_integer!() == 5
  end

  test "Zoi-invalid env override falls back to default" do
    # 99 is outside Zoi range 1..20 for test_integer
    System.put_env(@env_integer, "99")

    assert BullX.Config.TestSettings.test_integer!() == 10
  end

  test "missing database override with malformed env falls back to default" do
    System.put_env(@env_integer, "not_a_number")

    assert BullX.Config.TestSettings.test_integer!() == 10
  end

  test "missing database override with missing env uses default" do
    assert BullX.Config.TestSettings.test_integer!() == 10
  end

  test "Zoi-invalid database mode value falls back to env" do
    insert_config!(@db_key_mode, "turbo")
    BullX.Config.Cache.refresh(@db_key_mode)
    System.put_env(@env_mode, "fast")

    assert BullX.Config.TestSettings.test_mode!() == "fast"
  end

  test "Zoi-invalid env mode value falls back to default" do
    System.put_env(@env_mode, "turbo")

    assert BullX.Config.TestSettings.test_mode!() == "safe"
  end

  test "custom Skogsra type resolves correctly from the OS environment" do
    System.put_env(@env_custom, "hello")

    assert BullX.Config.TestCustomSettings.test_custom!() == {:demo, "hello"}
  end

  test "custom Skogsra type resolves correctly from the database override" do
    insert_config!(@db_key_custom, "world")
    BullX.Config.Cache.refresh(@db_key_custom)

    assert BullX.Config.TestCustomSettings.test_custom!() == {:demo, "world"}
  end

  defp insert_config!(key, value) do
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: key, value: value})
  end
end
