defmodule BullX.Config.WriterTest do
  use BullX.DataCase, async: false

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    on_exit(fn -> BullX.Config.Cache.refresh_all() end)
    :ok
  end

  test "put/2 upserts into database and populates ETS" do
    assert :ok = BullX.Config.Writer.put("writer.key1", "val1")

    assert %BullX.Config.AppConfig{value: "val1"} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.key1")

    assert {:ok, "val1"} = BullX.Config.Cache.get_raw("writer.key1")
  end

  test "put/2 updates an existing row on conflict" do
    assert :ok = BullX.Config.Writer.put("writer.key2", "first")
    assert :ok = BullX.Config.Writer.put("writer.key2", "second")

    assert %BullX.Config.AppConfig{value: "second"} =
             BullX.Repo.get!(BullX.Config.AppConfig, "writer.key2")

    assert {:ok, "second"} = BullX.Config.Cache.get_raw("writer.key2")
  end

  test "delete/1 removes the row and clears ETS" do
    BullX.Config.Writer.put("writer.del", "to_delete")
    assert {:ok, "to_delete"} = BullX.Config.Cache.get_raw("writer.del")

    assert :ok = BullX.Config.Writer.delete("writer.del")

    assert is_nil(BullX.Repo.get(BullX.Config.AppConfig, "writer.del"))
    assert :error = BullX.Config.Cache.get_raw("writer.del")
  end

  test "delete/1 is a no-op for nonexistent keys" do
    assert :ok = BullX.Config.Writer.delete("writer.nonexistent")
  end

  test "BullX.Config.put/2 delegates to Writer" do
    assert :ok = BullX.Config.put("facade.key", "facade_val")
    assert {:ok, "facade_val"} = BullX.Config.Cache.get_raw("facade.key")
  end

  test "BullX.Config.delete/1 delegates to Writer" do
    BullX.Config.put("facade.del", "x")
    assert :ok = BullX.Config.delete("facade.del")
    assert :error = BullX.Config.Cache.get_raw("facade.del")
  end
end
