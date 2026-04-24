defmodule BullXFeishu.StreamingCard do
  @moduledoc """
  Minimal Feishu streaming-card delivery state machine.

  The first implementation keeps stream state process-local inside the
  Gateway ScopeWorker task. A DLQ replay that has lost the enumerable returns a
  payload error instead of creating a placeholder card.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias BullXFeishu.{Config, Delivery, Error}

  @spec stream(BullXGateway.Delivery.t(), Enumerable.t() | nil, Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def stream(%GatewayDelivery{content: nil}, _enumerable, _config),
    do: {:error, Error.payload("stream content is not replayable")}

  def stream(%GatewayDelivery{} = delivery, nil, _config),
    do:
      {:error, Error.payload("stream content is not replayable", %{"delivery_id" => delivery.id})}

  def stream(%GatewayDelivery{} = delivery, enumerable, %Config{} = config) do
    with {:ok, chunks} <- collect_chunks(enumerable),
         text <- final_text(chunks),
         stream_delivery <- card_delivery(delivery, text),
         {:ok, %Outcome{} = outcome} <- Delivery.deliver(stream_delivery, config) do
      {:ok,
       %Outcome{
         outcome
         | delivery_id: delivery.id,
           warnings: outcome.warnings ++ stream_warnings(chunks)
       }}
    end
  end

  defp collect_chunks(enumerable) do
    try do
      {:ok, Enum.map(enumerable, &chunk_text/1)}
    rescue
      exception -> {:error, Error.map(exception)}
    catch
      kind, reason ->
        {:error, Error.map({kind, reason})}
    end
  end

  defp chunk_text(chunk) when is_binary(chunk), do: {:append, chunk}
  defp chunk_text(%{text: text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{"text" => text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{replace_text: text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(%{"replace_text" => text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(_), do: {:append, ""}

  defp final_text(chunks) do
    Enum.reduce(chunks, "", fn
      {:append, text}, acc -> acc <> text
      {:replace, text}, _acc -> text
    end)
  end

  defp card_delivery(%GatewayDelivery{} = delivery, text) do
    %GatewayDelivery{
      delivery
      | op: :send,
        content: %Content{
          kind: :card,
          body: %{
            "format" => "feishu.card",
            "fallback_text" => summary(text),
            "payload" => %{
              "config" => %{"wide_screen_mode" => true, "summary" => summary(text)},
              "elements" => [
                %{"tag" => "markdown", "content" => text}
              ]
            }
          }
        }
    }
  end

  defp summary(text) do
    text
    |> String.trim()
    |> case do
      "" -> BullX.I18n.t("gateway.feishu.delivery.stream_generating")
      value -> String.slice(value, 0, 80)
    end
  end

  defp stream_warnings(chunks) do
    if Enum.any?(chunks, &match?({:replace, _}, &1)), do: ["stream_replace_text_used"], else: []
  end
end
