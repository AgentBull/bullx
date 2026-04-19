defmodule BullX.Config.DotenvTest do
  use ExUnit.Case, async: false

  @test_vars ~w(DOTENV_BASE DOTENV_PROFILE DOTENV_LOCAL DOTENV_OVERRIDE)

  setup do
    original = Enum.map(@test_vars, &{&1, System.get_env(&1)})
    on_exit(fn -> restore_env(original) end)
    :ok
  end

  test "development load order: .env < .env.dev < .env.local < existing env" do
    in_tmp_dir(fn root ->
      write_env(root, ".env", "DOTENV_BASE=from_base\nDOTENV_OVERRIDE=from_base\n")
      write_env(root, ".env.dev", "DOTENV_PROFILE=from_dev\nDOTENV_OVERRIDE=from_dev\n")
      write_env(root, ".env.local", "DOTENV_LOCAL=from_local\nDOTENV_OVERRIDE=from_local\n")

      # existing env wins over all files
      System.put_env("DOTENV_OVERRIDE", "from_system")

      BullX.Config.Bootstrap.load_dotenv!(root: root, env: :dev)

      assert System.get_env("DOTENV_BASE") == "from_base"
      assert System.get_env("DOTENV_PROFILE") == "from_dev"
      assert System.get_env("DOTENV_LOCAL") == "from_local"
      assert System.get_env("DOTENV_OVERRIDE") == "from_system"
    end)
  end

  test "test load order: .env < .env.test, no .env.local" do
    in_tmp_dir(fn root ->
      write_env(root, ".env", "DOTENV_BASE=base_test\n")
      write_env(root, ".env.test", "DOTENV_PROFILE=test_profile\n")
      write_env(root, ".env.local", "DOTENV_LOCAL=should_be_ignored\n")

      BullX.Config.Bootstrap.load_dotenv!(root: root, env: :test)

      assert System.get_env("DOTENV_BASE") == "base_test"
      assert System.get_env("DOTENV_PROFILE") == "test_profile"
      # .env.local must not be loaded in test mode
      assert is_nil(System.get_env("DOTENV_LOCAL"))
    end)
  end

  test ".env.local is not loaded in prod mode" do
    in_tmp_dir(fn root ->
      write_env(root, ".env", "DOTENV_BASE=prod_base\n")
      write_env(root, ".env.prod", "DOTENV_PROFILE=prod_profile\n")
      write_env(root, ".env.local", "DOTENV_LOCAL=should_be_ignored\n")

      BullX.Config.Bootstrap.load_dotenv!(root: root, env: :prod)

      assert System.get_env("DOTENV_BASE") == "prod_base"
      assert System.get_env("DOTENV_PROFILE") == "prod_profile"
      assert is_nil(System.get_env("DOTENV_LOCAL"))
    end)
  end

  test "env_integer/2 parses valid integers and returns default for absent vars" do
    System.delete_env("DOTENV_BASE")
    assert BullX.Config.Bootstrap.env_integer("DOTENV_BASE", 42) == 42

    System.put_env("DOTENV_BASE", "100")
    assert BullX.Config.Bootstrap.env_integer("DOTENV_BASE", 42) == 100
  end

  test "env_integer/2 raises on malformed required integer" do
    System.put_env("DOTENV_BASE", "not_an_int")

    assert_raise RuntimeError, ~r/invalid integer/, fn ->
      BullX.Config.Bootstrap.env_integer("DOTENV_BASE")
    end
  end

  test "env_boolean/2 parses valid booleans and returns default for absent vars" do
    System.delete_env("DOTENV_BASE")
    assert BullX.Config.Bootstrap.env_boolean("DOTENV_BASE", false) == false

    System.put_env("DOTENV_BASE", "true")
    assert BullX.Config.Bootstrap.env_boolean("DOTENV_BASE") == true

    System.put_env("DOTENV_BASE", "1")
    assert BullX.Config.Bootstrap.env_boolean("DOTENV_BASE") == true

    System.put_env("DOTENV_BASE", "false")
    assert BullX.Config.Bootstrap.env_boolean("DOTENV_BASE") == false
  end

  test "env!/2 raises when required variable is absent" do
    System.delete_env("DOTENV_BASE")

    assert_raise RuntimeError, ~r/required environment variable/, fn ->
      BullX.Config.Bootstrap.env!("DOTENV_BASE", & &1)
    end
  end

  test "validate!/2 accepts Zoi-valid values" do
    schema = Zoi.integer(gte: 1, lte: 100)
    assert BullX.Config.Bootstrap.validate!(50, zoi: schema) == 50
  end

  test "validate!/2 raises on Zoi-invalid values" do
    schema = Zoi.integer(gte: 1, lte: 100)

    assert_raise RuntimeError, ~r/Zoi validation failed/, fn ->
      BullX.Config.Bootstrap.validate!(999, zoi: schema)
    end
  end

  defp in_tmp_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "bullx_dotenv_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp write_env(root, filename, content) do
    File.write!(Path.join(root, filename), content)
  end

  defp restore_env(pairs) do
    Enum.each(pairs, fn
      {key, nil} -> System.delete_env(key)
      {key, val} -> System.put_env(key, val)
    end)
  end
end
