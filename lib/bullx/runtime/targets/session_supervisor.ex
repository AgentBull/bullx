defmodule BullX.Runtime.Targets.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias BullX.Runtime.Targets.Session
  alias BullX.Runtime.Targets.SessionRegistry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_session(term()) :: {:ok, pid()} | {:error, term()}
  def ensure_session(session_key) do
    case SessionRegistry.lookup(session_key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        start_session(session_key)
    end
  end

  defp start_session(session_key) do
    case DynamicSupervisor.start_child(__MODULE__, {Session, session_key: session_key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end
end
