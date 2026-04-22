defmodule BullXGateway.Moderation do
  @moduledoc false

  alias BullXGateway.PolicyRunner
  alias BullXGateway.Telemetry
  alias Jido.Signal

  @type reason :: atom()
  @type description :: String.t()
  @type result ::
          :allow
          | {:reject, reason(), description()}
          | {:flag, reason(), description()}
          | {:modify, Signal.t()}

  @callback moderate(Signal.t(), keyword()) :: result()

  def apply_moderators(signal, moderators, opts \\ [], runner_opts \\ [])
      when is_list(moderators) do
    apply_moderators_loop(signal, moderators, opts, runner_opts, [], false)
  end

  defp apply_moderators_loop(signal, [], _opts, _runner_opts, flags, modified?) do
    {:ok, signal, Enum.reverse(flags), modified?}
  end

  defp apply_moderators_loop(signal, [moderator | rest], opts, runner_opts, flags, modified?) do
    case run_moderator(moderator, signal, opts, runner_opts) do
      :allow ->
        apply_moderators_loop(signal, rest, opts, runner_opts, flags, modified?)

      {:flag, flag} ->
        apply_moderators_loop(signal, rest, opts, runner_opts, [flag | flags], modified?)

      {:modify, modified_signal} ->
        apply_moderators_loop(modified_signal, rest, opts, runner_opts, flags, true)

      {:reject, reason, description} ->
        {:reject, reason, description}

      {:error, {:invalid_return, _, _}} = error ->
        error
    end
  end

  defp run_moderator(moderator, signal, opts, runner_opts) do
    timeout_ms = Keyword.get(runner_opts, :timeout_ms, 100)
    timeout_fallback = Keyword.get(runner_opts, :timeout_fallback, :deny)
    error_fallback = Keyword.get(runner_opts, :error_fallback, :deny)
    validate = Keyword.fetch!(runner_opts, :validate)

    case PolicyRunner.run(fn -> moderator.moderate(signal, opts) end, timeout_ms) do
      {:ok, :allow} ->
        emit_decision(moderator, :allow, nil)
        :allow

      {:ok, {:reject, reason, description}} ->
        emit_decision(moderator, :reject, reason)
        {:reject, reason, description}

      {:ok, {:flag, reason, description}} ->
        emit_decision(moderator, :flag, reason)
        {:flag, flag("moderation", moderator, Atom.to_string(reason), description)}

      {:ok, {:modify, %Signal{} = modified_signal}} ->
        case validate.(modified_signal) do
          {:ok, valid_signal} ->
            emit_decision(moderator, :modify, nil)
            {:modify, valid_signal}

          {:error, reason} ->
            {:error, {:invalid_return, moderator, reason}}
        end

      {:ok, other} ->
        {:error, {:invalid_return, moderator, other}}

      {:error, :timeout} ->
        handle_timeout_fallback(moderator, timeout_fallback)

      {:error, {:raised, reason}} ->
        handle_error_fallback(moderator, reason, error_fallback)
    end
  end

  defp handle_timeout_fallback(moderator, :allow_with_flag) do
    emit_decision(moderator, :allow_with_flag, :timeout_fallback)
    {:flag, flag("moderation", moderator, "timeout_fallback", "#{inspect(moderator)} timed out")}
  end

  defp handle_timeout_fallback(moderator, _fallback) do
    emit_decision(moderator, :reject, :timeout_fallback)
    {:reject, :timeout_fallback, "#{inspect(moderator)} timed out"}
  end

  defp handle_error_fallback(moderator, reason, :allow_with_flag) do
    emit_decision(moderator, :allow_with_flag, :error_fallback)

    {:flag,
     flag(
       "moderation",
       moderator,
       "error_fallback",
       "#{inspect(moderator)} errored: #{inspect(reason)}"
     )}
  end

  defp handle_error_fallback(moderator, reason, _fallback) do
    emit_decision(moderator, :reject, :error_fallback)
    {:reject, :error_fallback, "#{inspect(moderator)} errored: #{inspect(reason)}"}
  end

  defp emit_decision(module, decision, reason) do
    Telemetry.emit([:bullx, :gateway, :moderation, :decision], %{count: 1}, %{
      module: module,
      decision: decision,
      reason: reason
    })
  end

  defp flag(stage, module, reason, description) do
    %{
      "stage" => stage,
      "module" => inspect(module),
      "reason" => reason,
      "description" => description
    }
  end
end
