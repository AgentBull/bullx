defmodule BullXWeb.Plugs.FetchCurrentUser do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> get_session(:user_id)
    |> BullXAccounts.fetch_session_user()
    |> assign_current_user(conn)
  end

  defp assign_current_user({:ok, user}, conn), do: assign(conn, :current_user, user)

  defp assign_current_user({:error, _reason}, conn) do
    conn
    |> delete_session(:user_id)
    |> assign(:current_user, nil)
  end
end
