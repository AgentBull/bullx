defmodule BullXGateway.Gating do
  @moduledoc false

  alias BullXGateway.PolicyRunner
  alias BullXGateway.SignalContext
  alias BullXGateway.Telemetry

  @type reason :: atom()
  @type description :: String.t()
  @type result :: :allow | {:deny, reason(), description()}

  @callback check(SignalContext.t(), keyword()) :: result()

  def run_checks(%SignalContext{} = ctx, gaters, opts \\ [], runner_opts \\ [])
      when is_list(gaters) do
    case Enum.reduce_while(gaters, {:ok, []}, fn gater, {:ok, flags} ->
           case run_gater(gater, ctx, opts, runner_opts) do
             :allow ->
               {:cont, {:ok, flags}}

             {:allow_with_flag, flag} ->
               {:cont, {:ok, [flag | flags]}}

             {:deny, reason, description} ->
               {:halt, {:deny, reason, description}}
           end
         end) do
      {:ok, flags} -> {:ok, Enum.reverse(flags)}
      other -> other
    end
  end

  defp run_gater(gater, ctx, opts, runner_opts) do
    timeout_ms = Keyword.get(runner_opts, :timeout_ms, 50)
    timeout_fallback = Keyword.get(runner_opts, :timeout_fallback, :deny)
    error_fallback = Keyword.get(runner_opts, :error_fallback, :deny)

    case PolicyRunner.run(fn -> gater.check(ctx, opts) end, timeout_ms) do
      {:ok, :allow} ->
        emit_decision(gater, :allow, nil)
        :allow

      {:ok, {:deny, reason, description}} ->
        emit_decision(gater, :deny, reason)
        {:deny, reason, description}

      {:ok, other} ->
        handle_error_fallback(gater, {:invalid_return, other}, error_fallback)

      {:error, :timeout} ->
        handle_timeout_fallback(gater, timeout_fallback)

      {:error, {:raised, reason}} ->
        handle_error_fallback(gater, reason, error_fallback)
    end
  end

  defp handle_timeout_fallback(gater, :allow_with_flag) do
    flag = flag("gating", gater, "timeout_fallback", "#{inspect(gater)} timed out")
    emit_decision(gater, :allow_with_flag, :timeout_fallback)
    {:allow_with_flag, flag}
  end

  defp handle_timeout_fallback(gater, _fallback) do
    emit_decision(gater, :deny, :timeout_fallback)
    {:deny, :timeout_fallback, "#{inspect(gater)} timed out"}
  end

  defp handle_error_fallback(gater, reason, :allow_with_flag) do
    flag =
      flag("gating", gater, "error_fallback", "#{inspect(gater)} errored: #{inspect(reason)}")

    emit_decision(gater, :allow_with_flag, :error_fallback)
    {:allow_with_flag, flag}
  end

  defp handle_error_fallback(gater, reason, _fallback) do
    emit_decision(gater, :deny, :error_fallback)
    {:deny, :error_fallback, "#{inspect(gater)} errored: #{inspect(reason)}"}
  end

  defp emit_decision(module, decision, reason) do
    Telemetry.emit([:bullx, :gateway, :gating, :decision], %{count: 1}, %{
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
