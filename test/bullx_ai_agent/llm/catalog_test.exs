defmodule BullXAIAgent.LLM.CatalogTest do
  use BullX.DataCase, async: false

  alias BullXAIAgent.LLM.Catalog
  alias BullXAIAgent.LLM.Catalog.Cache
  alias BullXAIAgent.LLM.Crypto
  alias BullXAIAgent.LLM.Provider
  alias BullXAIAgent.LLM.ResolvedProvider
  alias BullXAIAgent.LLM.Writer

  setup do
    allow_cache()
    Cache.refresh_all()

    on_exit(fn -> Cache.refresh_all() end)

    :ok
  end

  test "resolve_alias/1 requires default to be configured" do
    assert Catalog.resolve_alias(:default) == {:error, {:not_configured, :default}}
    assert Catalog.default_alias_configured?() == false
  end

  test "resolve_alias/1 returns the provider-backed resolved struct" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs(api_key: "sk-test"))
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, provider.name})

    assert {:ok, %ResolvedProvider{} = resolved} = Catalog.resolve_alias(:default)
    assert resolved.model == %{provider: :openai, id: "gpt-4o-mini", base_url: provider.base_url}
    assert resolved.opts[:api_key] == "sk-test"
    assert resolved.opts[:provider_options] == [service_tier: "default"]
    assert Catalog.default_alias_configured?() == true
  end

  test "resolve_alias/1 converts JSON-backed provider option values for req_llm schemas" do
    assert {:ok, provider} =
             Writer.put_provider(
               provider_attrs(
                 provider_options: %{"auth_mode" => "oauth", "oauth_file" => "/tmp/auth.json"}
               )
             )

    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, provider.name})

    assert {:ok, %ResolvedProvider{} = resolved} = Catalog.resolve_alias(:default)
    assert Keyword.keyword?(resolved.opts[:provider_options])
    assert resolved.opts[:provider_options][:auth_mode] == :oauth
    assert resolved.opts[:provider_options][:oauth_file] == "/tmp/auth.json"
  end

  test "resolve_alias/1 converts JSON-backed map option keys for req_llm schemas" do
    assert {:ok, provider} =
             Writer.put_provider(
               provider_attrs(
                 provider_id: "openrouter",
                 provider_options: %{
                   "openrouter_usage" => %{"include" => true},
                   "openrouter_plugins" => [%{"id" => "web"}],
                   "openrouter_reasoning" => %{"max_tokens" => 2_000},
                   "openrouter_reasoning_effort" => "high"
                 }
               )
             )

    assert provider.provider_options["openrouter_usage"] == %{"include" => true}
    assert provider.provider_options["openrouter_plugins"] == [%{"id" => "web"}]
    assert provider.provider_options["openrouter_reasoning"] == %{"max_tokens" => 2_000}
    assert provider.provider_options["openrouter_reasoning_effort"] == "high"
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, provider.name})

    assert {:ok, %ResolvedProvider{} = resolved} = Catalog.resolve_alias(:default)
    assert Keyword.keyword?(resolved.opts[:provider_options])
    assert resolved.opts[:provider_options][:openrouter_usage] == %{include: true}
    assert resolved.opts[:provider_options][:openrouter_plugins] == [%{id: "web"}]
    assert resolved.opts[:provider_options][:openrouter_reasoning] == %{max_tokens: 2_000}
    assert resolved.opts[:provider_options][:openrouter_reasoning_effort] == :high
  end

  test "resolve_alias/1 converts Xiaomi MiMo billing plan option" do
    assert {:ok, provider} =
             Writer.put_provider(
               provider_attrs(
                 provider_id: "xiaomi_mimo",
                 model_id: "mimo-test",
                 provider_options: %{"xiaomi_mimo_billing_plan" => "token_plan"}
               )
             )

    assert provider.provider_options["xiaomi_mimo_billing_plan"] == "token_plan"
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, provider.name})

    assert {:ok, %ResolvedProvider{} = resolved} = Catalog.resolve_alias(:default)
    assert resolved.opts[:provider_options][:xiaomi_mimo_billing_plan] == :token_plan
  end

  test "unbound fast and heavy aliases directly reuse default provider" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs())
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, provider.name})

    assert Catalog.resolve_alias(:fast) == Catalog.resolve_alias(:default)
    assert Catalog.resolve_alias(:heavy) == Catalog.resolve_alias(:default)
  end

  test "unbound compression directly reuses resolved fast provider" do
    assert {:ok, _default} = Writer.put_provider(provider_attrs())
    assert {:ok, _fast} = Writer.put_provider(provider_attrs(name: "fast", model_id: "gpt-4o"))
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})
    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:provider, "fast"})

    assert Catalog.resolve_alias(:compression) == Catalog.resolve_alias(:fast)
    refute Catalog.resolve_alias(:compression) == Catalog.resolve_alias(:default)
  end

  test "non-default aliases can bind directly to a different provider" do
    assert {:ok, _default} = Writer.put_provider(provider_attrs())
    assert {:ok, _heavy} = Writer.put_provider(provider_attrs(name: "heavy", model_id: "gpt-4o"))
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})
    assert {:ok, _binding} = Writer.put_alias_binding(:heavy, {:provider, "heavy"})

    assert {:ok, resolved} = Catalog.resolve_alias(:heavy)
    assert resolved.model.id == "gpt-4o"
  end

  test "non-default aliases can reuse another model alias" do
    assert {:ok, _default} = Writer.put_provider(provider_attrs())
    assert {:ok, _fast} = Writer.put_provider(provider_attrs(name: "fast", model_id: "gpt-4o"))
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})
    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:provider, "fast"})
    assert {:ok, _binding} = Writer.put_alias_binding(:compression, {:alias, :fast})

    assert Catalog.list_alias_bindings()[:compression] == {:alias, :fast}
    assert Catalog.resolve_alias(:compression) == Catalog.resolve_alias(:fast)
    refute Catalog.resolve_alias(:compression) == Catalog.resolve_alias(:default)
  end

  test "compression can explicitly reuse default model" do
    assert {:ok, _default} = Writer.put_provider(provider_attrs())
    assert {:ok, _fast} = Writer.put_provider(provider_attrs(name: "fast", model_id: "gpt-4o"))
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})
    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:provider, "fast"})
    assert {:ok, _binding} = Writer.put_alias_binding(:compression, {:alias, :default})

    assert Catalog.resolve_alias(:compression) == Catalog.resolve_alias(:default)
    refute Catalog.resolve_alias(:compression) == Catalog.resolve_alias(:fast)
  end

  test "resolve_alias/1 surfaces decrypt failures without fallback" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs(api_key: "sk-test"))
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, provider.name})

    provider
    |> Provider.changeset(%{encrypted_api_key: "garbage"})
    |> Repo.update!()

    Cache.refresh_all()

    assert Catalog.resolve_alias(:default) == {:error, {:decrypt_failed, "primary"}}
  end

  test "encrypted api keys are bound to the provider id" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs(api_key: "sk-test"))
    other_id = BullX.Ext.gen_uuid_v7()

    assert {:error, _reason} = Crypto.decrypt_api_key(provider.encrypted_api_key, other_id)
  end

  defp provider_attrs(overrides \\ []) do
    %{
      name: "primary",
      provider_id: "openai",
      model_id: "gpt-4o-mini",
      base_url: "https://api.openai.com/v1",
      provider_options: %{"service_tier" => "default"}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp allow_cache do
    case Process.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
