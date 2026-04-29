defmodule BullXWeb.PageControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User

  test "GET / redirects to setup when users is empty and a bootstrap code is pending",
       %{conn: conn} do
    Repo.delete_all(ActivationCode)
    {:ok, _result} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / falls through to /sessions/new when users is empty but no bootstrap code is pending",
       %{conn: conn} do
    Repo.delete_all(ActivationCode)

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/sessions/new"
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
