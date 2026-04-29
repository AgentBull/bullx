defmodule BullXAIAgent.ModelAliasesTest do
  use ExUnit.Case, async: true

  alias BullXAIAgent.ModelAliases

  describe "aliases/0" do
    test "returns only the supported aliases" do
      assert ModelAliases.aliases() == [:default, :fast, :heavy, :compression]
    end
  end

  describe "alias?/1" do
    test "accepts supported aliases and rejects unknown aliases" do
      for alias_name <- [:default, :fast, :heavy, :compression] do
        assert ModelAliases.alias?(alias_name)
      end

      refute ModelAliases.alias?(:unsupported)
    end
  end

  describe "resolve_model/1" do
    test "rejects unknown aliases" do
      assert_raise ArgumentError, ~r/Unknown model alias/, fn ->
        ModelAliases.resolve_model(:unsupported)
      end
    end
  end
end
