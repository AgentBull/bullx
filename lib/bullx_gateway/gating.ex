defmodule BullXGateway.Gating do
  @moduledoc """
  Executes the gating stage of the inbound policy pipeline.

  Gaters answer whether a canonical inbound signal may proceed at all, using a
  `BullXGateway.SignalContext`. Unlike moderation, gating never rewrites the
  signal: it either allows, or terminates the pipeline, with optional
  allow-with-flag fallback when timeout or error policy says to fail open.
  """

  alias BullXGateway.PolicyRunner
  alias BullXGateway.SignalContext

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
        :allow

      {:ok, {:deny, reason, description}} ->
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
    {:allow_with_flag, flag}
  end

  defp handle_timeout_fallback(gater, _fallback) do
    {:deny, :timeout_fallback, "#{inspect(gater)} timed out"}
  end

  defp handle_error_fallback(gater, reason, :allow_with_flag) do
    flag =
      flag("gating", gater, "error_fallback", "#{inspect(gater)} errored: #{inspect(reason)}")

    {:allow_with_flag, flag}
  end

  defp handle_error_fallback(gater, reason, _fallback) do
    {:deny, :error_fallback, "#{inspect(gater)} errored: #{inspect(reason)}"}
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
