defmodule BullX.Config.ReqLLM.Bridge do
  @moduledoc """
  Pushes BullX-owned ReqLLM config into req_llm's application environment.

  The bridge owns no process or state. `Application` remains the state owner
  because upstream req_llm already reads these values through
  `Application.get_env/2`.
  """

  @spec sync_all!() :: :ok
  def sync_all! do
    Enum.each(BullX.Config.ReqLLM.bridge_keyspec(), fn {key, fun} ->
      Application.put_env(:req_llm, key, fun.())
    end)

    :ok
  end

  @spec sync_key!(String.t()) :: :ok
  def sync_key!(_bullx_key), do: sync_all!()
end
