defmodule BullXAIAgent.LLM do
  @moduledoc """
  Public LLM-side surface for BullXAIAgent.

  `BullXAIAgent.Supervisor.init/1` invokes `register_custom_providers/0` once
  at boot. Custom `ReqLLM.Provider` implementations are registered in code
  because the underlying req_llm registry is keyed by provider modules.
  """

  @doc """
  Registers BullX-internal custom `ReqLLM.Provider` modules.
  """
  @spec register_custom_providers() :: :ok
  def register_custom_providers do
    ReqLLM.Providers.register!(BullXAIAgent.LLM.Providers.OpenRouter)
    ReqLLM.Providers.register!(BullXAIAgent.LLM.Providers.VolcengineArk)
    ReqLLM.Providers.register!(BullXAIAgent.LLM.Providers.XiaomiMiMo)

    :ok
  end
end
