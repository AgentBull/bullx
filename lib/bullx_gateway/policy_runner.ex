defmodule BullXGateway.PolicyRunner do
  @moduledoc """
  Runs Gateway policy callbacks inside a bounded task boundary.

  Security, gating, and moderation hooks are application-supplied code. Gateway
  does not execute them inline in the caller process; it runs them under
  `BullXGateway.PolicyTaskSupervisor`, enforces a timeout, and normalizes
  crashes into explicit `{:error, ...}` results so pipeline stages can apply
  fail-open or fail-closed policy deterministically.
  """

  @task_supervisor BullXGateway.PolicyTaskSupervisor

  def run(fun, timeout_ms)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> invoke(fun) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, {:raised, reason}}} -> {:error, {:raised, reason}}
      {:exit, reason} -> {:error, {:raised, normalize_exit(reason)}}
      nil -> {:error, :timeout}
    end
  end

  defp invoke(fun) do
    try do
      {:ok, fun.()}
    rescue
      exception ->
        {:error, {:raised, Exception.message(exception)}}
    catch
      :exit, reason ->
        {:error, {:raised, normalize_exit(reason)}}

      kind, reason ->
        {:error, {:raised, {kind, reason}}}
    end
  end

  defp normalize_exit({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  defp normalize_exit(reason), do: reason
end
