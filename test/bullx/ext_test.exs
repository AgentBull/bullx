defmodule BullX.ExtTest do
  use ExUnit.Case, async: true

  test "generic_hash/2 returns the expected hex digest" do
    assert BullX.Ext.generic_hash("bullx") ==
             "7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706"
  end

  test "bs58_hash/2 returns the expected base58 digest" do
    assert BullX.Ext.bs58_hash("bullx") == "9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ"
  end

  test "derive_key/3 returns the expected derived key" do
    assert BullX.Ext.derive_key("seed", "tenant-A", "scope-a") ==
             "0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20"
  end

  test "generate_key/0 returns a hex-encoded 32-byte key" do
    key = BullX.Ext.generate_key()

    assert is_binary(key)
    assert byte_size(key) == 64
    assert key =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "native salt parsing errors remain tagged tuples" do
    assert {:error, reason} = BullX.Ext.generic_hash("abc", "bad")
    assert reason =~ "invalid salt"
  end

  test "nifs normalize invalid argument types" do
    assert BullX.Ext.generic_hash(123) == {:error, "data must be a binary"}
    assert BullX.Ext.generic_hash("abc", 123) == {:error, "salt must be a string or nil"}
    assert BullX.Ext.bs58_hash(123) == {:error, "data must be a binary"}
    assert BullX.Ext.derive_key(123, "tenant-A") == {:error, "key_seed must be a binary"}
    assert BullX.Ext.derive_key("seed", 123) == {:error, "sub_key_id must be a string"}

    assert BullX.Ext.derive_key("seed", "tenant-A", 123) ==
             {:error, "extra_context must be a string or nil"}
  end
end
