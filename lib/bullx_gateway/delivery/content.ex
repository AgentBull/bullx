defmodule BullXGateway.Delivery.Content do
  @moduledoc """
  Shared content block contract used by Gateway inbound and outbound paths.
  """

  @type kind :: :text | :image | :audio | :video | :file | :card

  @type t :: %__MODULE__{
          kind: kind(),
          body: map()
        }

  defstruct [:kind, body: %{}]
end
