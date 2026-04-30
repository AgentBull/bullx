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

  test "put_secret/2 stores ciphertext in database and returns plaintext from ETS" do
    assert :ok = BullX.Config.Writer.put_secret("writer.secret1", "my-secret-value")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "writer.secret1")
    assert row.type == :secret
    assert row.value != "my-secret-value"
    assert String.contains?(row.value, ".")

    assert {:ok, "my-secret-value"} = BullX.Config.Cache.get_raw("writer.secret1")
  end

  test "put_secret/2 updates an existing secret on conflict" do
    assert :ok = BullX.Config.Writer.put_secret("writer.secret2", "first-secret")
    assert :ok = BullX.Config.Writer.put_secret("writer.secret2", "second-secret")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "writer.secret2")
    assert row.type == :secret
    assert {:ok, "second-secret"} = BullX.Config.Cache.get_raw("writer.secret2")
  end

  test "put_secret/2 overwrites a plain key and changes its type to secret" do
    assert :ok = BullX.Config.Writer.put("writer.upgrade", "plain-value")
    assert {:ok, "plain-value"} = BullX.Config.Cache.get_raw("writer.upgrade")

    assert :ok = BullX.Config.Writer.put_secret("writer.upgrade", "secret-value")

    row = BullX.Repo.get!(BullX.Config.AppConfig, "writer.upgrade")
    assert row.type == :secret
    assert {:ok, "secret-value"} = BullX.Config.Cache.get_raw("writer.upgrade")
  end
end
