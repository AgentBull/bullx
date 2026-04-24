defmodule BullXWeb.PageControllerTest do
  use BullXWeb.ConnCase

  alias BullXAccounts.User

  test "GET / redirects to setup when no user exists", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / redirects to sign-in when setup is complete and no user is signed in", %{conn: conn} do
    insert_user!(display_name: "Alice")

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/sessions/new"
  end

  test "GET / renders the control-panel SPA when signed in", %{conn: conn} do
    user = insert_user!(display_name: "Alice")

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/")

    assert html_response(conn, 200) =~ "control-panel/App"
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end
end
