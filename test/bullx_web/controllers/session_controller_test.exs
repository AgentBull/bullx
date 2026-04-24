defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.User
  alias BullXAccounts.UserChannelAuthCode
  alias BullXAccounts.UserChannelBinding

  test "GET /login renders the auth-code form", %{conn: conn} do
    conn = get(conn, ~p"/login")

    assert html_response(conn, 200) =~ "Authentication code"
  end

  test "POST /login consumes a channel auth code and stores only the user id in session", %{
    conn: conn
  } do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    conn = post(conn, ~p"/login", %{"session" => %{"auth_code" => code}})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
    assert Repo.aggregate(UserChannelAuthCode, :count) == 0
  end

  test "POST /login rejects expired or invalid codes", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"session" => %{"auth_code" => "NOPE"}})

    assert redirected_to(conn) == ~p"/login"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Invalid or expired authentication code."
  end

  test "banned users cannot establish a web session with an existing code", %{conn: conn} do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    user
    |> User.changeset(%{status: :banned})
    |> Repo.update!()

    conn = post(conn, ~p"/login", %{"session" => %{"auth_code" => code}})

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :user_id) == nil
  end

  test "DELETE /logout clears the session and redirects to /login", %{conn: conn} do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    conn = post(conn, ~p"/login", %{"session" => %{"auth_code" => code}})
    assert get_session(conn, :user_id) == user.id

    conn = delete(conn, ~p"/logout")

    assert redirected_to(conn) == ~p"/login"
    assert get_session(conn, :user_id) == nil
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp insert_binding!(user, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:user_id, user.id)
      |> Map.put_new(:metadata, %{})

    %UserChannelBinding{}
    |> UserChannelBinding.changeset(attrs)
    |> Repo.insert!()
  end
end
