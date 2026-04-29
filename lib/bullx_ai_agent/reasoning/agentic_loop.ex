defmodule BullXAIAgent.Reasoning.AgenticLoop do
  @moduledoc """
  Public API for Task-based AgenticLoop runtime.

  This module provides process-resident streaming execution that can be reused by
  actions and strategies.
  """

  alias Jido.Agent.Strategy.State, as: StratState
  alias BullXAIAgent.Reasoning.AgenticLoop.{Config, Runner, State}

  @type config_input :: Config.t() | map() | keyword()

  @doc """
  Starts a new AgenticLoop run and returns a lazy event stream.
  """
  @spec stream(String.t(), config_input(), keyword()) :: Enumerable.t()
  def stream(query, config, opts \\ []) when is_binary(query) and is_list(opts) do
    config = build_config(config)
    Runner.stream(query, config, opts)
  end

  @doc """
  Resumes a AgenticLoop run from state and returns a lazy event stream.
  """
  @spec stream_from_state(State.t(), config_input(), keyword()) :: Enumerable.t()
  def stream_from_state(%State{} = state, config, opts \\ []) when is_list(opts) do
    config = build_config(config)
    Runner.stream_from_state(state, config, opts)
  end

  @doc """
  Runs AgenticLoop to completion and returns an aggregated result map.
  """
  @spec run(String.t(), config_input(), keyword()) :: map()
  def run(query, config, opts \\ []) when is_binary(query) and is_list(opts) do
    query
    |> stream(config, opts)
    |> collect_stream()
  end

  @doc """
  Starts a run and returns run metadata plus a stream handle.
  """
  @spec start(String.t(), config_input(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(query, config, opts \\ []) when is_binary(query) and is_list(opts) do
    config = build_config(config)

    state = State.new(query, config.system_prompt, Keyword.take(opts, [:request_id, :run_id]))
    events = Runner.stream(query, config, Keyword.put(opts, :state, state))

    {:ok,
     %{
       run_id: state.run_id,
       request_id: state.request_id,
       events: events
     }}
  rescue
    e -> {:error, e}
  end

  @doc """
  Collects run output from an event stream.
  """
  @spec collect(Enumerable.t(), config_input(), keyword()) :: {:ok, map()} | {:error, term()}
  def collect(events, _config, _opts) do
    {:ok, collect_stream(events)}
  rescue
    e -> {:error, e}
  end

  @doc """
  Steers an active AgenticLoop-backed agent with additional user-visible input.

  Returns `{:ok, agent}` when the input is queued for the current run or
  `{:error, {:rejected, reason}}` when no eligible run is active.

  Queued input is best-effort. If the run terminates before the runtime drains
  the queue into conversation state, the queued input is dropped.
  """
  @spec steer(GenServer.server(), String.t(), keyword()) ::
          {:ok, Jido.Agent.t()} | {:error, term()}
  def steer(agent_server, content, opts \\ []) when is_binary(content) and is_list(opts) do
    control(agent_server, "ai.agentic_loop.steer", content, opts, :steer)
  end

  @doc """
  Injects user-visible input into an active AgenticLoop-backed agent.

  This is intended for programmatic or inter-agent steering and follows the same
  queuing rules as `steer/3`.
  """
  @spec inject(GenServer.server(), String.t(), keyword()) ::
          {:ok, Jido.Agent.t()} | {:error, term()}
  def inject(agent_server, content, opts \\ []) when is_binary(content) and is_list(opts) do
    control(agent_server, "ai.agentic_loop.inject", content, opts, :inject)
  end

  @doc """
  Normalizes user-provided configuration into a `Config` struct.
  """
  @spec build_config(config_input()) :: Config.t()
  def build_config(%Config{} = config), do: config
  def build_config(config), do: Config.new(config)

  @doc """
  Reduces a AgenticLoop event stream into terminal result, usage, and full trace.
  """
  @spec collect_stream(Enumerable.t()) :: map()
  def collect_stream(events) do
    acc =
      Enum.reduce(events, initial_collect_acc(), fn event, acc ->
        acc
        |> Map.update!(:trace, &[event | &1])
        |> update_collect_from_event(event)
      end)

    %{
      result: acc.result,
      termination_reason: acc.termination_reason,
      usage: acc.usage,
      trace: Enum.reverse(acc.trace)
    }
  end

  defp initial_collect_acc do
    %{
      result: nil,
      termination_reason: nil,
      usage: %{},
      trace: []
    }
  end

  defp update_collect_from_event(acc, %{kind: :request_completed, data: data}) do
    %{
      acc
      | result: Map.get(data, :result),
        termination_reason: Map.get(data, :termination_reason, :final_answer),
        usage: Map.get(data, :usage, acc.usage)
    }
  end

  defp update_collect_from_event(acc, %{kind: :request_failed, data: data}) do
    %{acc | result: Map.get(data, :error), termination_reason: :failed}
  end

  defp update_collect_from_event(acc, %{kind: :request_cancelled, data: _data}) do
    %{acc | termination_reason: :cancelled}
  end

  defp update_collect_from_event(acc, _event), do: acc

  defp control(agent_server, signal_type, content, opts, kind)
       when is_binary(signal_type) and is_binary(content) and kind in [:steer, :inject] do
    timeout = Keyword.get(opts, :timeout, 5_000)

    signal =
      Jido.Signal.new!(
        signal_type,
        %{
          content: content
        }
        |> maybe_put_control_opt(:expected_request_id, Keyword.get(opts, :expected_request_id))
        |> maybe_put_control_opt(:source, Keyword.get(opts, :source, "/ai/agentic_loop"))
        |> maybe_put_control_opt(:extra_refs, Keyword.get(opts, :extra_refs)),
        source: "/ai/agentic_loop"
      )

    case Jido.AgentServer.call(agent_server, signal, timeout) do
      {:ok, agent} ->
        normalize_control_result(agent, kind)

      {:error, _} = error ->
        error
    end
  end

  defp maybe_put_control_opt(payload, _key, nil), do: payload
  defp maybe_put_control_opt(payload, key, value), do: Map.put(payload, key, value)

  defp normalize_control_result(%Jido.Agent{} = agent, kind) do
    case StratState.get(agent, %{}) |> Map.get(:last_pending_input_control) do
      %{kind: ^kind, status: :queued} ->
        {:ok, agent}

      %{kind: ^kind, status: :rejected, reason: reason} ->
        {:error, {:rejected, reason}}

      _ ->
        {:error, :unknown_control_result}
    end
  end
end
