defmodule BullXAIAgent.LLM.WriterTest do
  use BullX.DataCase, async: false

  alias BullXAIAgent.LLM.Catalog
  alias BullXAIAgent.LLM.Catalog.Cache
  alias BullXAIAgent.LLM.Crypto
  alias BullXAIAgent.LLM.Writer

  setup do
    allow_cache()
    Cache.refresh_all()

    on_exit(fn -> Cache.refresh_all() end)

    :ok
  end

  test "put_provider/1 encrypts api_key before persistence" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs(api_key: "sk-test"))
    assert is_binary(provider.encrypted_api_key)
    refute provider.encrypted_api_key == "sk-test"
    assert Crypto.decrypt_api_key(provider.encrypted_api_key, provider.id) == {:ok, "sk-test"}
  end

  test "put_provider/1 accepts providers without api_key" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs())
    assert provider.encrypted_api_key == nil
  end

  test "put_provider/1 rejects provider options outside the req_llm provider schema" do
    assert {:error, {:invalid_provider_options, {:unknown_options, ["unknown_option"]}}} =
             Writer.put_provider(provider_attrs(provider_options: %{"unknown_option" => true}))
  end

  test "put_provider/1 accepts JSON object values for schema-declared map options" do
    assert {:ok, provider} =
             Writer.put_provider(
               provider_attrs(
                 provider_id: "openrouter",
                 provider_options: %{
                   "openrouter_usage" => %{"include" => true},
                   "openrouter_reasoning" => %{"max_tokens" => 2_000},
                   "openrouter_reasoning_effort" => "high"
                 }
               )
             )

    assert provider.provider_options["openrouter_usage"] == %{"include" => true}
    assert provider.provider_options["openrouter_reasoning"] == %{"max_tokens" => 2_000}
    assert provider.provider_options["openrouter_reasoning_effort"] == "high"
  end

  test "put_provider/1 accepts Xiaomi MiMo billing plan option" do
    assert {:ok, provider} =
             Writer.put_provider(
               provider_attrs(
                 provider_id: "xiaomi_mimo",
                 provider_options: %{"xiaomi_mimo_billing_plan" => "token_plan"}
               )
             )

    assert provider.provider_options["xiaomi_mimo_billing_plan"] == "token_plan"
  end

  test "update_provider/2 preserves and clears api_key intentionally" do
    assert {:ok, provider} = Writer.put_provider(provider_attrs(api_key: "sk-test"))
    encrypted = provider.encrypted_api_key

    assert {:ok, provider} = Writer.update_provider(provider, provider_attrs(model_id: "gpt-4o"))
    assert provider.encrypted_api_key == encrypted

    assert {:ok, provider} = Writer.update_provider(provider, provider_attrs(api_key: nil))
    assert provider.encrypted_api_key == nil
  end

  test "delete_provider/1 rejects providers still referenced by an alias" do
    assert {:ok, _provider} = Writer.put_provider(provider_attrs())
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})

    assert Writer.delete_provider("primary") == {:error, {:still_referenced_by_alias, :default}}
  end

  test "put_alias_binding/2 accepts provider targets and non-default alias targets" do
    assert {:ok, _provider} = Writer.put_provider(provider_attrs())

    assert Writer.put_alias_binding(:default, {:alias, :fast}) ==
             {:error, {:default_alias_must_target_provider, :default}}

    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:alias, :default})
    assert Catalog.list_alias_bindings()[:fast] == {:alias, :default}

    assert Writer.put_alias_binding(:fast, {:provider, "absent"}) ==
             {:error, {:unknown_provider, "absent"}}

    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:provider, "primary"})
    assert Catalog.list_alias_bindings()[:fast] == {:provider, "primary"}
  end

  test "put_alias_binding/2 rejects alias cycles" do
    assert {:ok, _provider} = Writer.put_provider(provider_attrs())
    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})
    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:alias, :heavy})

    assert {:error, {:alias_cycle, [:fast, :heavy, :fast]}} =
             Writer.put_alias_binding(:heavy, {:alias, :fast})

    assert {:error, {:alias_cycle, [:fast, :compression, :fast]}} =
             Writer.put_alias_binding(:fast, {:alias, :compression})
  end

  test "delete_alias_binding/1 rejects deletes that would create an implicit fallback cycle" do
    assert {:ok, _default} = Writer.put_provider(provider_attrs())

    assert {:ok, _compression} =
             Writer.put_provider(provider_attrs(name: "compression", model_id: "gpt-4o"))

    assert {:ok, _binding} = Writer.put_alias_binding(:default, {:provider, "primary"})
    assert {:ok, _binding} = Writer.put_alias_binding(:compression, {:provider, "compression"})
    assert {:ok, _binding} = Writer.put_alias_binding(:fast, {:alias, :compression})

    assert {:error, {:alias_cycle, [:fast, :compression, :fast]}} =
             Writer.delete_alias_binding(:compression)
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
