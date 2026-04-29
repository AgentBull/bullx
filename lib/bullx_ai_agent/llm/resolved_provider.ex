defmodule BullXAIAgent.LLM.ResolvedProvider do
  @moduledoc false

  @enforce_keys [:model, :opts]
  defstruct [:model, :opts]

  @type t :: %__MODULE__{
          model: ReqLLM.model_input(),
          opts: keyword()
        }
end
