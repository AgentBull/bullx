defmodule BullXWeb.SetupController do
  use BullXWeb, :controller

  def show(conn, _params) do
    case BullXAccounts.setup_required?() do
      true -> render_setup(conn)
      false -> redirect(conn, to: ~p"/")
    end
  end

  defp render_setup(conn) do
    conn
    |> assign(:page_title, "Setup")
    |> assign_prop(:app_name, "BullX")
    |> render_inertia("setup/App")
  end
end
