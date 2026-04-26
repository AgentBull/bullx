defmodule BullX.I18n.ResolverTest do
  use ExUnit.Case, async: false

  alias BullX.I18n.Resolver

  describe "fallback_chain/1" do
    setup do
      # Any test that rewrites the Catalog's persistent_term entries must
      # restore them afterwards so later tests don't see drift.
      on_exit(fn -> BullX.I18n.Catalog.reload_locales!() end)
      :ok
    end

    test "places meta fallback before the default backstop" do
      Resolver.put_catalog(:"zh-Hans-CN", %{}, %{fallback: "ja-JP"})
      Resolver.put_catalog(:"ja-JP", %{}, %{})
      Resolver.put_catalog(:"en-US", %{}, %{})
      Resolver.put_loaded([:"zh-Hans-CN", :"ja-JP", :"en-US"])

      chain = Resolver.fallback_chain(:"zh-Hans-CN")
      ja_idx = Enum.find_index(chain, &(&1 == :"ja-JP"))
      en_us_idx = Enum.find_index(chain, &(&1 == :"en-US"))
      assert ja_idx != nil
      assert en_us_idx != nil
      assert ja_idx < en_us_idx
    end

    test "filters unloaded locales" do
      Resolver.put_loaded([:"en-US"])
      assert Resolver.fallback_chain(:"ja-JP") == [:"en-US"]
    end
  end
end
