defmodule BullXWeb.HealthController do
  use BullXWeb, :controller

  alias BullX.Health

  def livez(conn, _params) do
    json(conn, Health.live())
  end

  def readyz(conn, _params) do
    case Health.ready() do
      {:ok, report} ->
        json(conn, report)

      {:error, report} ->
        conn
        |> put_status(:service_unavailable)
        |> json(report)
    end
  end
end
