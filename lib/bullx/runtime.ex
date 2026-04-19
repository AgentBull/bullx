defmodule BullX.Runtime do
  @moduledoc """
  The long-lived process layer. Owns session processes, LLM/tool task pools,
  sub-agent supervision, and cron scheduling with exactly-once semantics across
  restarts.

  RFC-000 establishes the namespace and an empty top-level supervisor; runtime
  services are added by later RFCs.
  """
end
