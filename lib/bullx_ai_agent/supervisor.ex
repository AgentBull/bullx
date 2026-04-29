defmodule BullXAIAgent.Supervisor do
  @moduledoc """
  Top-level supervisor for AIAgent runtime workers.

  Owns the LLM provider catalog cache today; future AIAgent workers can be
  added here without changing another subsystem's failure boundary.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    BullXAIAgent.LLM.register_custom_providers()

    children = [
      BullXAIAgent.LLM.Catalog.Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
