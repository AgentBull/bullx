defmodule BullXAIAgent.Signal.Ext.BullXAI do
  @moduledoc false

  use Jido.Signal.Ext,
    namespace: "bullx.ai",
    schema: []
end

defmodule BullXAIAgent.Signal do
  @moduledoc """
  Typed Signal wrapper for the BullX AI Agent subsystem.

  BullX compiles with warnings as errors. Hex `jido_signal` 2.1.x emits an
  Elixir 1.20 type warning when a typed signal has an empty extension policy,
  so BullX AI signals reserve an optional `bullx.ai` extension namespace while
  still delegating the Signal implementation to `Jido.Signal`.
  """

  @extension_policy_anchor {BullXAIAgent.Signal.Ext.BullXAI, :optional}

  defmacro __using__(opts) do
    opts =
      opts
      |> Macro.expand(__CALLER__)
      |> put_extension_policy_anchor()

    quote location: :keep do
      use Jido.Signal, unquote(Macro.escape(opts))
    end
  end

  defp put_extension_policy_anchor(opts) do
    Keyword.update(opts, :extension_policy, [@extension_policy_anchor], fn policy ->
      if Enum.any?(policy, fn
           {BullXAIAgent.Signal.Ext.BullXAI, _mode} -> true
           _other -> false
         end) do
        policy
      else
        [@extension_policy_anchor | policy]
      end
    end)
  end
end
