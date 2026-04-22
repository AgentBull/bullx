defmodule BullX.Config.TestCustomType do
  use Skogsra.Type

  @impl Skogsra.Type
  def cast(value) when is_binary(value) do
    {:ok, {:demo, value}}
  end

  def cast(_value) do
    :error
  end
end
