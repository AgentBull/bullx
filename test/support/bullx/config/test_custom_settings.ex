defmodule BullX.Config.TestCustomSettings do
  use BullX.Config

  @envdoc false
  bullx_env(:test_custom,
    type: BullX.Config.TestCustomType,
    default: {:demo, "fallback"}
  )
end
