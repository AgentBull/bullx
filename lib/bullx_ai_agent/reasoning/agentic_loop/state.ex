defmodule BullXAIAgent.Reasoning.AgenticLoop.State do
  @moduledoc """
  Runtime state for a single AgenticLoop run.
  """

  alias BullXAIAgent.Reasoning.AgenticLoop.PendingToolCall
  alias BullXAIAgent.Context, as: AIContext

  @status_values [:running, :awaiting_tools, :completed, :failed, :cancelled]
  @version 3

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.default(@version),
              run_id: Zoi.string(),
              request_id: Zoi.string(),
              status: Zoi.atom() |> Zoi.default(:running),
              iteration: Zoi.integer() |> Zoi.default(1),
              llm_call_id: Zoi.string() |> Zoi.nullish(),
              llm_response_id: Zoi.string() |> Zoi.nullish(),
              context: Zoi.any(),
              active_tools: Zoi.map() |> Zoi.default(%{}),
              pending_tool_calls: Zoi.list(PendingToolCall.schema()) |> Zoi.default([]),
              usage: Zoi.map() |> Zoi.default(%{}),
              result: Zoi.any() |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              started_at_ms: Zoi.integer() |> Zoi.default(0),
              updated_at_ms: Zoi.integer() |> Zoi.default(0),
              seq: Zoi.integer() |> Zoi.default(0)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the Zoi schema used to validate AgenticLoop runtime state.
  """
  @spec schema() :: term()
  def schema, do: @schema

  @doc """
  Creates initial runtime state for a new query.
  """
  @spec new(String.t(), String.t() | nil, keyword()) :: t()
  def new(query, system_prompt, opts \\ []) when is_binary(query) do
    now = now_ms()

    request_id = Keyword.get(opts, :request_id, "req_#{Jido.Util.generate_id()}")
    run_id = Keyword.get(opts, :run_id, "run_#{Jido.Util.generate_id()}")

    context =
      AIContext.new(system_prompt: system_prompt)
      |> AIContext.append_user(query)

    attrs = %{
      run_id: run_id,
      request_id: request_id,
      status: :running,
      iteration: 1,
      llm_response_id: nil,
      context: context,
      active_tools: %{},
      pending_tool_calls: [],
      usage: %{},
      started_at_ms: now,
      updated_at_ms: now,
      seq: 0
    }

    parse_or_raise(attrs)
  end

  @doc """
  Increments the event sequence counter and returns `{state, next_seq}`.
  """
  @spec bump_seq(t()) :: {t(), pos_integer()}
  def bump_seq(%__MODULE__{} = state) do
    next = state.seq + 1
    {%{state | seq: next, updated_at_ms: now_ms()}, next}
  end

  @doc """
  Increments the reasoning iteration counter.
  """
  @spec inc_iteration(t()) :: t()
  def inc_iteration(%__MODULE__{} = state) do
    %{state | iteration: state.iteration + 1, updated_at_ms: now_ms()}
  end

  @doc """
  Sets runtime status.
  """
  @spec put_status(t(), atom()) :: t()
  def put_status(%__MODULE__{} = state, status) when status in @status_values do
    %{state | status: status, updated_at_ms: now_ms()}
  end

  @doc """
  Stores the current LLM call id.
  """
  @spec put_llm_call_id(t(), String.t() | nil) :: t()
  def put_llm_call_id(%__MODULE__{} = state, call_id) do
    %{state | llm_call_id: call_id, updated_at_ms: now_ms()}
  end

  @doc """
  Stores the latest provider response id for multi-turn continuation.
  """
  @spec put_llm_response_id(t(), String.t() | nil) :: t()
  def put_llm_response_id(%__MODULE__{} = state, response_id) do
    %{state | llm_response_id: response_id, updated_at_ms: now_ms()}
  end

  @doc """
  Replaces pending tool calls.
  """
  @spec put_pending_tools(t(), [PendingToolCall.t()]) :: t()
  def put_pending_tools(%__MODULE__{} = state, pending) when is_list(pending) do
    %{state | pending_tool_calls: pending, updated_at_ms: now_ms()}
  end

  @doc """
  Clears all pending tool calls.
  """
  @spec clear_pending_tools(t()) :: t()
  def clear_pending_tools(%__MODULE__{} = state) do
    %{state | pending_tool_calls: [], updated_at_ms: now_ms()}
  end

  @doc """
  Stores terminal result value.
  """
  @spec put_result(t(), term()) :: t()
  def put_result(%__MODULE__{} = state, result) do
    %{state | result: result, updated_at_ms: now_ms()}
  end

  @doc """
  Stores terminal error value.
  """
  @spec put_error(t(), term()) :: t()
  def put_error(%__MODULE__{} = state, error) do
    %{state | error: error, updated_at_ms: now_ms()}
  end

  @doc """
  Merges usage counters into existing state usage map.
  """
  @spec merge_usage(t(), map() | nil) :: t()
  def merge_usage(%__MODULE__{} = state, nil), do: state

  def merge_usage(%__MODULE__{} = state, usage) when is_map(usage) do
    merged =
      Map.merge(state.usage, usage, fn _k, old, new ->
        normalize_numeric(old) + normalize_numeric(new)
      end)

    %{state | usage: merged, updated_at_ms: now_ms()}
  end

  def merge_usage(%__MODULE__{} = state, _), do: state

  @doc """
  Returns elapsed runtime in milliseconds.
  """
  @spec duration_ms(t()) :: non_neg_integer()
  def duration_ms(%__MODULE__{} = state) do
    max(now_ms() - state.started_at_ms, 0)
  end

  defp parse_or_raise(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, state} -> state
      {:error, errors} -> raise ArgumentError, "invalid AgenticLoop state: #{inspect(errors)}"
    end
  end

  defp normalize_numeric(value) when is_integer(value), do: value
  defp normalize_numeric(value) when is_float(value), do: trunc(value)

  defp normalize_numeric(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp normalize_numeric(_), do: 0

  defp now_ms, do: System.system_time(:millisecond)
end
