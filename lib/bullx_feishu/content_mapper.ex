defmodule BullXFeishu.ContentMapper do
  @moduledoc """
  Converts Feishu message payloads into Gateway content blocks.
  """

  alias BullXGateway.Delivery.Content

  @media_types ~w(image file audio video)

  @spec from_message(map(), BullXFeishu.Config.t()) :: {:ok, [Content.t()]} | {:error, map()}
  def from_message(message, config) when is_map(message) do
    type = Map.get(message, "message_type") || Map.get(message, :message_type)
    body = decoded_content(message)

    blocks =
      case type do
        "text" -> [text_block(text_from_body(body))]
        "post" -> [text_block(post_text(body))]
        "interactive" -> [card_block(body)]
        "image" -> [media_block(:image, message, body, config)]
        "file" -> [media_block(:file, message, body, config)]
        "audio" -> [media_block(:audio, message, body, config)]
        "video" -> [media_block(:video, message, body, config)]
        "sticker" -> [text_block("[sticker]")]
        "emotion" -> [text_block(emotion_text(body))]
        "emoji" -> [text_block(emotion_text(body))]
        nil -> [text_block(text_from_body(body))]
        _ -> [text_block(fallback_text(type))]
      end

    {:ok, Enum.reject(blocks, &is_nil/1)}
  end

  def from_message(_message, _config),
    do: {:error, BullXFeishu.Error.payload("invalid Feishu message")}

  @spec primary_text([Content.t()]) :: String.t() | nil
  def primary_text([%Content{kind: :text, body: %{"text" => text}} | _]) when is_binary(text),
    do: text

  def primary_text([_ | rest]), do: primary_text(rest)
  def primary_text([]), do: nil

  @spec render_outbound(Content.t()) :: {:ok, map(), [String.t()]} | {:error, map()}
  def render_outbound(%Content{kind: :text, body: %{"text" => text}}) when is_binary(text) do
    {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, []}
  end

  def render_outbound(%Content{kind: :card, body: %{"format" => format, "payload" => payload}})
      when format in ["feishu.card", "feishu.card.v2"] and is_map(payload) do
    {:ok, %{msg_type: "interactive", content: Jason.encode!(payload)}, []}
  end

  def render_outbound(%Content{kind: kind, body: body})
      when kind in [:image, :audio, :video, :file] do
    case Map.get(body, "fallback_text") do
      text when is_binary(text) and text != "" ->
        {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})},
         ["#{kind}_degraded_to_fallback_text"]}

      _ ->
        {:error, BullXFeishu.Error.unsupported("Feishu #{kind} delivery requires fallback_text")}
    end
  end

  def render_outbound(%Content{} = content) do
    {:error,
     BullXFeishu.Error.unsupported("unsupported Feishu content kind", %{
       "kind" => Atom.to_string(content.kind)
     })}
  end

  defp decoded_content(%{"content" => content}), do: decode_content(content)
  defp decoded_content(%{content: content}), do: decode_content(content)
  defp decoded_content(_), do: %{}

  defp decode_content(content) when is_map(content), do: content

  defp decode_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"text" => content}
    end
  end

  defp decode_content(_), do: %{}

  defp text_from_body(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp text_from_body(%{"title" => title}) when is_binary(title), do: String.trim(title)
  defp text_from_body(_), do: ""

  defp post_text(%{"title" => title, "content" => content}) do
    [title, flatten_post_content(content)]
    |> Enum.filter(&present?/1)
    |> Enum.join("\n")
  end

  defp post_text(%{"content" => content}), do: flatten_post_content(content)
  defp post_text(other), do: text_from_body(other)

  defp flatten_post_content(content) when is_list(content) do
    content
    |> List.flatten()
    |> Enum.map(&post_fragment/1)
    |> Enum.filter(&present?/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp flatten_post_content(_), do: ""

  defp post_fragment(%{"tag" => "text", "text" => text}) when is_binary(text), do: text
  defp post_fragment(%{"tag" => "a", "text" => text}) when is_binary(text), do: text
  defp post_fragment(%{"tag" => "at", "user_name" => name}) when is_binary(name), do: "@" <> name
  defp post_fragment(_), do: ""

  defp card_block(payload) when is_map(payload) do
    %Content{
      kind: :card,
      body: %{
        "format" => "feishu.card",
        "fallback_text" => card_fallback(payload),
        "payload" => payload
      }
    }
  end

  defp media_block(kind, message, body, _config) when kind in [:image, :audio, :video, :file] do
    message_id = Map.get(message, "message_id") || Map.get(message, :message_id) || "unknown"
    key = media_key(body, kind)
    filename = Map.get(body, "file_name") || Map.get(body, "name")
    fallback = filename || "[#{kind}]"

    %Content{
      kind: kind,
      body:
        %{
          "url" => "feishu://message-resource/#{message_id}/#{key || kind}",
          "fallback_text" => fallback
        }
        |> maybe_put("filename", filename)
    }
  end

  defp media_key(body, :image), do: Map.get(body, "image_key")
  defp media_key(body, :file), do: Map.get(body, "file_key")
  defp media_key(body, :audio), do: Map.get(body, "file_key") || Map.get(body, "audio_key")
  defp media_key(body, :video), do: Map.get(body, "file_key") || Map.get(body, "video_key")

  defp text_block(text) do
    text =
      case String.trim(to_string(text)) do
        "" -> BullX.I18n.t("gateway.feishu.errors.unsupported_message")
        value -> value
      end

    %Content{kind: :text, body: %{"text" => text}}
  end

  defp emotion_text(%{"emoji_type" => emoji}) when is_binary(emoji), do: ":" <> emoji <> ":"
  defp emotion_text(%{"text" => text}) when is_binary(text), do: text
  defp emotion_text(_), do: "[sticker]"

  defp fallback_text(type) when type in @media_types, do: "[#{type}]"
  defp fallback_text(_), do: BullX.I18n.t("gateway.feishu.errors.unsupported_message")

  defp card_fallback(%{"header" => %{"title" => %{"content" => content}}})
       when is_binary(content),
       do: content

  defp card_fallback(%{"config" => %{"summary" => summary}}) when is_binary(summary), do: summary
  defp card_fallback(_), do: "[card]"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
