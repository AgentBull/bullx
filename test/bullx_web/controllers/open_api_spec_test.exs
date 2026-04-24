defmodule BullXWeb.OpenApiSpecTest do
  use BullXWeb.ConnCase, async: true

  test "GET /.well-known/service-desc renders the OpenAPI document", %{conn: conn} do
    conn = get(conn, ~p"/.well-known/service-desc")
    spec = Jason.decode!(response(conn, 200))

    assert get_in(spec, ["paths", "/.well-known/service-desc", "get", "operationId"]) ==
             "BullXWeb.ApiSpec.service_desc"

    refute Map.has_key?(spec["paths"], "/api/openapi")
  end

  test "GET /api/openapi is not exposed", %{conn: conn} do
    conn = get(conn, "/api/openapi")

    assert response(conn, 404)
  end
end
