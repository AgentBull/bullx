defmodule BullXAIAgent.LLM.CustomProviderTest do
  use ExUnit.Case, async: false

  alias BullXAIAgent.LLM.Providers.OpenRouter
  alias BullXAIAgent.LLM.Providers.VolcengineArk
  alias BullXAIAgent.LLM.Providers.XiaomiMiMo

  test "register_custom_providers/0 registers BullX custom providers with req_llm" do
    assert :ok = BullXAIAgent.LLM.register_custom_providers()
    assert :openrouter in ReqLLM.Providers.list()
    assert :volcengine_ark in ReqLLM.Providers.list()
    assert :xiaomi_mimo in ReqLLM.Providers.list()
    assert ReqLLM.Providers.get(:openrouter) == {:ok, OpenRouter}
    assert ReqLLM.Providers.get(:volcengine_ark) == {:ok, VolcengineArk}
    assert ReqLLM.Providers.get(:xiaomi_mimo) == {:ok, XiaomiMiMo}
  end

  test "OpenRouter shadows req_llm built-in provider with BullX reasoning encoding" do
    assert OpenRouter.provider_id() == :openrouter
    assert OpenRouter.default_base_url() == "https://openrouter.ai/api/v1"
    assert OpenRouter.default_env_key() == "OPENROUTER_API_KEY"

    schema = OpenRouter.provider_schema().schema
    assert Keyword.has_key?(schema, :openrouter_usage)
    assert Keyword.has_key?(schema, :openrouter_reasoning_effort)
    assert Keyword.has_key?(schema, :openrouter_reasoning)
    refute Keyword.has_key?(schema, :reasoning_effort)
  end

  test "OpenRouter encodes reasoning effort with OpenRouter unified reasoning object" do
    assert {:ok, request} =
             OpenRouter.prepare_request(
               :chat,
               %{provider: :openrouter, id: "openai/gpt-5.5"},
               "ping",
               api_key: "sk-test",
               max_tokens: 16,
               provider_options: [
                 openrouter_reasoning_effort: :high,
                 openrouter_usage: %{include: true}
               ]
             )

    body =
      request
      |> OpenRouter.encode_body()
      |> Map.fetch!(:body)
      |> Jason.decode!()

    assert body["reasoning"] == %{"effort" => "high"}
    assert body["usage"] == %{"include" => true}
    refute Map.has_key?(body, "reasoning_effort")
  end

  test "OpenRouter raw reasoning object takes precedence over effort" do
    assert {:ok, request} =
             OpenRouter.prepare_request(
               :chat,
               %{provider: :openrouter, id: "openai/gpt-5.5"},
               "ping",
               api_key: "sk-test",
               max_tokens: 16,
               provider_options: [
                 openrouter_reasoning: %{max_tokens: 2_000},
                 openrouter_reasoning_effort: :high
               ]
             )

    body =
      request
      |> OpenRouter.encode_body()
      |> Map.fetch!(:body)
      |> Jason.decode!()

    assert body["reasoning"] == %{"max_tokens" => 2_000}
    refute Map.has_key?(body, "reasoning_effort")
  end

  test "Volcengine Ark uses OpenAI-compatible defaults with Ark base URL" do
    assert VolcengineArk.provider_id() == :volcengine_ark
    assert VolcengineArk.default_base_url() == "https://ark.cn-beijing.volces.com/api/v3"
    assert VolcengineArk.default_env_key() == "ARK_API_KEY"
    assert VolcengineArk.provider_schema().schema == []
  end

  test "Xiaomi MiMo uses Anthropic-compatible defaults with MiMo base URL" do
    assert XiaomiMiMo.provider_id() == :xiaomi_mimo
    assert XiaomiMiMo.default_base_url() == "https://api.xiaomimimo.com/anthropic"
    assert XiaomiMiMo.default_env_key() == "XIAOMI_MIMO_API_KEY"

    schema = XiaomiMiMo.provider_schema().schema
    assert Keyword.has_key?(schema, :anthropic_version)
    assert Keyword.has_key?(schema, :xiaomi_mimo_billing_plan)
  end

  test "Xiaomi MiMo builds requests against the Anthropic-compatible messages endpoint" do
    assert {:ok, request} =
             XiaomiMiMo.prepare_request(
               :chat,
               %{provider: :xiaomi_mimo, id: "mimo-test"},
               "ping",
               api_key: "sk-test"
             )

    assert request.options[:base_url] == "https://api.xiaomimimo.com/anthropic"
    assert URI.to_string(request.url) == "/v1/messages"
    assert Req.Request.get_header(request, "x-api-key") == ["sk-test"]
    assert Req.Request.get_header(request, "anthropic-version") == ["2023-06-01"]
  end

  test "Xiaomi MiMo Token Plan uses the token-plan-cn Anthropic-compatible base URL" do
    assert {:ok, request} =
             XiaomiMiMo.prepare_request(
               :chat,
               %{
                 provider: :xiaomi_mimo,
                 id: "mimo-test",
                 base_url: "https://api.xiaomimimo.com/anthropic"
               },
               "ping",
               api_key: "sk-token-plan",
               provider_options: [xiaomi_mimo_billing_plan: :token_plan]
             )

    assert request.options[:base_url] == "https://token-plan-cn.xiaomimimo.com/anthropic"
    assert URI.to_string(request.url) == "/v1/messages"
    assert Req.Request.get_header(request, "x-api-key") == ["sk-token-plan"]
    refute Keyword.has_key?(request.options[:provider_options] || [], :xiaomi_mimo_billing_plan)
  end
end
