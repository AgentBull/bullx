defmodule BullXWeb.HealthControllerTest do
  use BullXWeb.ConnCase, async: true

  test "GET /livez only checks the local node", %{conn: conn} do
    conn = get(conn, ~p"/livez")

    assert %{
             "status" => "ok",
             "checks" => %{"beam" => %{"status" => "ok"}}
           } = json_response(conn, 200)
  end

  test "GET /readyz checks PostgreSQL readiness", %{conn: conn} do
    conn = get(conn, ~p"/readyz")

    assert %{
             "status" => "ok",
             "checks" => %{"postgres" => %{"status" => "ok"}}
           } = json_response(conn, 200)
  end
end
