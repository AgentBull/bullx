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

    assert %BullX.Config.AppConfig{value: "val1", type: :plain} =
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

  test "put/2 encrypts and stores as :secret for keys declared with secret: true" do
    assert :ok = BullX.Config.Writer.put("bullx.test_secret", "my-sensitive-value")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "bullx.test_secret")
    assert row.type == :secret
    assert row.value != "my-sensitive-value"
    assert String.contains?(row.value, ".")

    assert {:ok, "my-sensitive-value"} = BullX.Config.Cache.get_raw("bullx.test_secret")
  end

  test "put/2 re-encrypts on overwrite of a secret key" do
    assert :ok = BullX.Config.Writer.put("bullx.test_secret", "first")
    assert :ok = BullX.Config.Writer.put("bullx.test_secret", "second")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "bullx.test_secret")
    assert row.type == :secret
    assert {:ok, "second"} = BullX.Config.Cache.get_raw("bullx.test_secret")
  end
end
