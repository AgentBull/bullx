defmodule BullX.UUIDPrimaryKeyAuditTest do
  use ExUnit.Case, async: true

  @lib_files Path.wildcard("lib/**/*.ex")
  @migration_files Path.wildcard("priv/repo/migrations/*.exs")

  @forbidden_schema_patterns [
    {
      ~r/@primary_key\s*\{\s*:\w+\s*,\s*:binary_id\s*,/s,
      "uses `:binary_id` for a primary key; use `BullX.Ecto.UUIDv7` instead"
    },
    {
      ~r/@primary_key\s*\{\s*:\w+\s*,\s*:uuid\s*,/s,
      "uses `:uuid` for a primary key; use `BullX.Ecto.UUIDv7` instead"
    },
    {
      ~r/@primary_key\s*\{\s*:\w+\s*,\s*Ecto\.UUID\s*,/s,
      "uses `Ecto.UUID` for a primary key; use `BullX.Ecto.UUIDv7` instead"
    },
    {
      ~r/field\s+:\w+\s*,\s*:binary_id\s*,\s*primary_key:\s*true/s,
      "declares a `:binary_id` primary-key field; use `BullX.Ecto.UUIDv7` instead"
    },
    {
      ~r/field\s+:\w+\s*,\s*:uuid\s*,\s*primary_key:\s*true/s,
      "declares a `:uuid` primary-key field; use `BullX.Ecto.UUIDv7` instead"
    },
    {
      ~r/field\s+:\w+\s*,\s*Ecto\.UUID\s*,\s*primary_key:\s*true/s,
      "declares an `Ecto.UUID` primary-key field; use `BullX.Ecto.UUIDv7` instead"
    }
  ]

  @forbidden_migration_patterns [
    {
      ~r/default:\s*fragment\(\s*"[^"]*(gen_random_uuid|uuid_generate_v\d+|uuidv7|uuid_generate_v7)\s*\(/s,
      "uses a database-side UUID default; generate UUIDv7 in BullX code instead"
    },
    {
      ~r/DEFAULT\s+(gen_random_uuid|uuid_generate_v\d+|uuidv7|uuid_generate_v7)\s*\(/is,
      "uses a database-side UUID default in SQL; generate UUIDv7 in BullX code instead"
    }
  ]

  test "BullX.Ecto.UUIDv7 autogenerates canonical UUIDv7 values" do
    uuid = BullX.Ecto.UUIDv7.autogenerate()

    assert BullX.Ecto.UUIDv7.type() == :uuid
    assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert {:ok, ^uuid} = BullX.Ecto.UUIDv7.cast(uuid)
    assert {:ok, dumped} = BullX.Ecto.UUIDv7.dump(uuid)
    assert {:ok, ^uuid} = BullX.Ecto.UUIDv7.load(dumped)
  end

  test "schemas with UUID primary keys use BullX.Ecto.UUIDv7" do
    offenders =
      @lib_files
      |> Enum.flat_map(&schema_uuid_primary_key_offenses/1)

    assert offenders == []
  end

  test "migrations do not delegate UUID primary key generation to PostgreSQL" do
    offenders =
      @migration_files
      |> Enum.flat_map(&migration_uuid_default_offenses/1)

    assert offenders == []
  end

  defp schema_uuid_primary_key_offenses(path) do
    source = File.read!(path)

    for {pattern, reason} <- @forbidden_schema_patterns,
        Regex.match?(pattern, source) do
      "#{path}: #{reason}"
    end
  end

  defp migration_uuid_default_offenses(path) do
    source = File.read!(path)

    for {pattern, reason} <- @forbidden_migration_patterns,
        Regex.match?(pattern, source) do
      "#{path}: #{reason}"
    end
  end
end
