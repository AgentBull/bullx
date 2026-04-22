defmodule BullXAIAgent do
  @moduledoc """
  The AI Agent behavior layer. Prompt types, reasoning strategies (FSM / DAG /
  behavior tree), and decision logic. Forked from jido_ai v2.1.0 and
  substantially rewritten for BullX's needs, so BullX does not depend on
  `jido_ai` as a package.

  RFC-000 establishes the namespace only; this pure library subsystem does not
  boot a top-level supervisor.
  """
end
