defmodule BullXGateway.DedupeKey do
  @moduledoc false

  @spec generate(String.t(), String.t()) :: String.t()
  def generate(source, external_id) when is_binary(source) and is_binary(external_id) do
    :sha256
    |> :crypto.hash("#{source}|#{external_id}")
    |> Base.encode16(case: :lower)
  end
end
