defmodule BullXGateway.Webhook.RawBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, cache_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, cache_body(conn, body)}

      other ->
        other
    end
  end

  defp cache_body(conn, body) do
    update_in(conn.assigns, fn assigns ->
      Map.update(assigns, :raw_body, [body], &[body | &1])
    end)
  end
end
