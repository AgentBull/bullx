defmodule BullXFeishu.WebhookPlug do
  @moduledoc """
  Plug entry point for Feishu event and card-action webhooks.

  The plug reads the exact raw request body and delegates signature,
  decryption, and challenge handling to the FeishuOpenAPI SDK.
  """

  import Plug.Conn

  alias BullXFeishu.{Channel, Config}
  alias FeishuOpenAPI.CardAction.Handler
  alias FeishuOpenAPI.Event.Dispatcher

  def init(opts) do
    channel = Keyword.fetch!(opts, :channel)
    config = Config.normalize!(channel, Keyword.fetch!(opts, :config))

    %{
      channel: channel,
      config: config,
      dispatcher: Channel.event_dispatcher(channel, config),
      card_handler: Channel.card_action_handler(channel, config)
    }
  end

  def call(conn, %{config: %Config{webhook: nil}}) do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  def call(conn, %{config: %Config{webhook: webhook}, dispatcher: dispatcher} = opts) do
    path = "/" <> Enum.join(conn.path_info, "/")

    cond do
      path == webhook.event_path ->
        dispatch_event(conn, dispatcher)

      path == webhook.card_action_path ->
        dispatch_card_action(conn, opts.card_handler)

      true ->
        send_json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp dispatch_event(conn, %Dispatcher{} = dispatcher) do
    with {:ok, body, conn} <- raw_body(conn),
         result <- Dispatcher.dispatch(dispatcher, {:raw, body, conn.req_headers}) do
      respond(conn, result)
    else
      {:error, _reason, conn} -> send_json(conn, 400, %{"error" => "invalid_body"})
    end
  end

  defp dispatch_card_action(conn, %Handler{} = handler) do
    with {:ok, body, conn} <- raw_body(conn),
         result <- Handler.dispatch(handler, {:raw, body, conn.req_headers}) do
      respond(conn, result)
    else
      {:error, _reason, conn} -> send_json(conn, 400, %{"error" => "invalid_body"})
    end
  end

  defp respond(conn, {:challenge, challenge}),
    do: send_json(conn, 200, %{"challenge" => challenge})

  defp respond(conn, {:ok, response}) when is_map(response), do: send_json(conn, 200, response)
  defp respond(conn, {:ok, _response}), do: send_json(conn, 200, %{})
  defp respond(conn, {:error, _reason}), do: send_json(conn, 400, %{"error" => "bad_request"})

  defp raw_body(%Plug.Conn{assigns: %{raw_body: parts}} = conn) when is_list(parts) do
    {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary(), conn}
  end

  defp raw_body(conn) do
    case read_body(conn, length: 1_048_576) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _body, conn} -> {:error, :too_large, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
