defmodule BullXGateway.Delivery.Content do
  @moduledoc """
  Shared content block contract used by Gateway inbound and outbound paths.

  The six `kind` values are `:text | :image | :audio | :video | :file | :card`.
  Every non-`:text` kind MUST carry a non-empty `body["fallback_text"]` string:
  this is the hard rule that makes degradation tractable for adapters that do
  not natively support a content kind (RFC 0003 §5.2, §6.4).
  """

  @type kind :: :text | :image | :audio | :video | :file | :card

  @type t :: %__MODULE__{
          kind: kind(),
          body: map()
        }

  @enforce_keys [:kind]
  defstruct [:kind, body: %{}]

  @kinds ~w(text image audio video file card)a

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{kind: kind, body: body}) when kind in @kinds and is_map(body) do
    with :ok <- validate_fallback_text(kind, body),
         :ok <- validate_kind_body(kind, body) do
      :ok
    end
  end

  def validate(%__MODULE__{kind: kind}), do: {:error, {:invalid_kind, kind}}
  def validate(other), do: {:error, {:not_a_content, other}}

  defp validate_fallback_text(:text, _body), do: :ok

  defp validate_fallback_text(_kind, body) do
    case body["fallback_text"] do
      fallback when is_binary(fallback) and fallback != "" -> :ok
      _ -> {:error, :missing_fallback_text}
    end
  end

  defp validate_kind_body(:text, %{"text" => text}) when is_binary(text), do: :ok
  defp validate_kind_body(:text, _), do: {:error, :invalid_text_body}

  defp validate_kind_body(kind, body) when kind in [:image, :audio, :video, :file] do
    case body["url"] do
      url when is_binary(url) and url != "" -> :ok
      _ -> {:error, {:invalid_media_body, kind}}
    end
  end

  defp validate_kind_body(:card, body) do
    cond do
      not is_binary(body["format"]) or body["format"] == "" -> {:error, :invalid_card_format}
      not is_map(body["payload"]) -> {:error, :invalid_card_payload}
      true -> :ok
    end
  end
end
