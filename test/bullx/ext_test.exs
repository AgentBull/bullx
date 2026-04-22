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

  test "uuid helpers generate canonical and short forms" do
    uuid = BullX.Ext.gen_uuid()
    short_uuid = BullX.Ext.uuid_shorten(uuid)

    assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert is_binary(short_uuid)
    assert BullX.Ext.short_uuid_expand(short_uuid) == uuid
  end

  test "gen_uuid_v7/0 returns a UUID v7 string" do
    assert BullX.Ext.gen_uuid_v7() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "gen_base36_uuid/0 returns a lowercase base36 string" do
    assert BullX.Ext.gen_base36_uuid() =~ ~r/\A[0-9a-z]+\z/
  end

  test "uuid helpers return tagged errors for invalid input" do
    assert {:error, reason} = BullX.Ext.uuid_shorten("not-a-uuid")
    assert reason != ""

    assert {:error, reason} = BullX.Ext.short_uuid_expand("not-valid$$")
    assert reason != ""
  end

  test "base58 helpers round trip binary payloads" do
    payload = <<0, 255, 1, 2, 3>>
    encoded = BullX.Ext.base58_encode(payload)

    assert is_binary(encoded)
    assert BullX.Ext.base58_decode(encoded) == payload
  end

  test "base64 helpers use url safe encoding without padding" do
    assert BullX.Ext.base64_url_safe_encode("bullx") == "YnVsbHg"
    assert BullX.Ext.base64_url_safe_decode("YnVsbHg") == "bullx"
  end

  test "any_ascii/1 transliterates unicode strings" do
    assert BullX.Ext.any_ascii("Björk") == "Bjork"
  end

  test "z85 helpers round trip aligned binary payloads" do
    encoded = BullX.Ext.z85_encode("bull")

    assert is_binary(encoded)
    assert BullX.Ext.z85_decode(encoded) == "bull"
  end

  test "z85_encode/1 rejects payloads whose length is not divisible by 4" do
    assert BullX.Ext.z85_encode("abc") == {:error, "input length must be divisible by 4"}
  end
end
