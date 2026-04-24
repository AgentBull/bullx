defmodule BullXWeb.SetupControllerTest do
  use BullXWeb.ConnCase

  alias BullXAccounts.User

  test "GET /setup renders the setup SPA when no user exists", %{conn: conn} do
    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ "setup/App"
  end

  test "GET /setup redirects home once a user exists", %{conn: conn} do
    insert_user!(display_name: "Alice")

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/"
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end
end
