defmodule BullX.Runtime.Targets.Executor do
  @moduledoc false

  alias BullX.Runtime.Targets.Kind.Blackhole
  alias BullX.Runtime.Targets.SessionKey
  alias BullX.Runtime.Targets.SessionSupervisor
  alias BullX.Runtime.Targets.Session
  alias BullX.Runtime.Targets.Target
  alias BullXAIAgent.Kind.AgenticChatLoop
  alias Jido.Signal

  @kind_modules %{
    "agentic_chat_loop" => AgenticChatLoop,
    "blackhole" => Blackhole
  }

  @spec supported_kinds() :: [String.t()]
  def supported_kinds, do: Map.keys(@kind_modules)

  @spec kind_module(String.t()) :: {:ok, module()} | {:error, term()}
  def kind_module(kind) when is_binary(kind) do
    case Map.fetch(@kind_modules, kind) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_target_kind, kind}}
    end
  end

  @spec execute(map(), Signal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(resolution, signal, opts \\ [])

  def execute(
        %{target: %Target{kind: "blackhole"} = target} = resolution,
        %Signal{} = signal,
        opts
      ) do
    with {:ok, module} <- kind_module(target.kind) do
      module.run(%{target: target, route: resolution.route, signal: signal}, opts)
    end
  end

  def execute(
        %{target: %Target{kind: "agentic_chat_loop"} = target} = resolution,
        %Signal{} = signal,
        opts
      ) do
    with {:ok, module} <- kind_module(target.kind),
         {:ok, session_key} <- SessionKey.from_signal(target.key, signal),
         {:ok, session} <- SessionSupervisor.ensure_session(session_key) do
      Session.turn(session, resolution, signal, Keyword.put(opts, :kind_module, module))
    end
  end

  def execute(%{target: %Target{kind: kind}}, %Signal{}, _opts),
    do: {:error, {:unsupported_target_kind, kind}}
end
