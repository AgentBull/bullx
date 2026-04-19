defmodule BullX.Config.CacheTest do
  use BullX.DataCase, async: false

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    on_exit(fn -> BullX.Config.Cache.refresh_all() end)
    :ok
  end

  test "ETS table is accessible on boot" do
    assert is_pid(GenServer.whereis(BullX.Config.Cache))
    assert :error = BullX.Config.Cache.get_raw("nonexistent.key")
  end

  test "refresh/1 makes an inserted row visible" do
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: "test.cache_key", value: "hello"})
    BullX.Config.Cache.refresh("test.cache_key")

    assert {:ok, "hello"} = BullX.Config.Cache.get_raw("test.cache_key")
  end

  test "refresh/1 removes a deleted row from ETS" do
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: "test.cache_del", value: "bye"})
    BullX.Config.Cache.refresh("test.cache_del")
    assert {:ok, "bye"} = BullX.Config.Cache.get_raw("test.cache_del")

    BullX.Repo.delete!(%BullX.Config.AppConfig{key: "test.cache_del"})
    BullX.Config.Cache.refresh("test.cache_del")

    assert :error = BullX.Config.Cache.get_raw("test.cache_del")
  end

  test "refresh_all/0 reloads the full table" do
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: "test.reload_a", value: "1"})
    BullX.Repo.insert!(%BullX.Config.AppConfig{key: "test.reload_b", value: "2"})
    BullX.Config.Cache.refresh_all()

    assert {:ok, "1"} = BullX.Config.Cache.get_raw("test.reload_a")
    assert {:ok, "2"} = BullX.Config.Cache.get_raw("test.reload_b")
  end
end
