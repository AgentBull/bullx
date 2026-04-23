defmodule BullX.I18n.ResolverTest do
  use ExUnit.Case, async: false

  alias BullX.I18n.Resolver

  describe "parents/1" do
    test "splits a BCP 47 tag into ancestors, most specific first" do
      assert Resolver.parents(:"zh-Hans-CN") == [:"zh-Hans", :zh]
      assert Resolver.parents(:"en-US") == [:en]
      assert Resolver.parents(:en) == []
    end
  end

  describe "fallback_chain/1" do
    setup do
      # Any test that rewrites the Catalog's persistent_term entries must
      # restore them afterwards so later tests don't see drift.
      on_exit(fn -> BullX.I18n.Catalog.reload_locales!() end)
      :ok
    end

    test "same-language parents precede meta fallback" do
      Resolver.put_catalog(:"zh-Hans-CN", %{}, %{fallback: "en-US"})
      Resolver.put_catalog(:"zh-Hans", %{}, %{})
      Resolver.put_catalog(:"en-US", %{}, %{})
      Resolver.put_loaded([:"zh-Hans-CN", :"zh-Hans", :"en-US"])

      chain = Resolver.fallback_chain(:"zh-Hans-CN")
      zh_hans_idx = Enum.find_index(chain, &(&1 == :"zh-Hans"))
      en_us_idx = Enum.find_index(chain, &(&1 == :"en-US"))
      assert zh_hans_idx != nil
      assert en_us_idx != nil
      assert zh_hans_idx < en_us_idx
    end

    test "filters unloaded locales" do
      Resolver.put_loaded([:"en-US"])
      assert Resolver.fallback_chain(:"ja-JP") == [:"en-US"]
    end
  end
end
