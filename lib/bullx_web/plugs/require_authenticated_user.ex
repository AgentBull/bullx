defmodule BullXWeb.Plugs.RequireAuthenticatedUser do
  @moduledoc false

  use BullXWeb, :verified_routes

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias BullXAccounts.User

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_flash(:error, "Sign in to continue.")
    |> redirect(to: ~p"/login")
    |> halt()
  end
end
