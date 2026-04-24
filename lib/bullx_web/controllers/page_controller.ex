defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  alias BullXAccounts.User

  def home(conn, _params) do
    case {BullXAccounts.setup_required?(), conn.assigns[:current_user]} do
      {true, _current_user} -> redirect(conn, to: ~p"/setup")
      {false, %User{} = user} -> render_control_panel(conn, user)
      {false, _missing_user} -> redirect(conn, to: ~p"/sessions/new")
    end
  end

  defp render_control_panel(conn, user) do
    conn
    |> assign(:page_title, "Control Panel")
    |> assign_prop(:app_name, "BullX")
    |> assign_prop(:current_user, user_props(user))
    |> assign_prop(:swagger_ui_path, swagger_ui_path())
    |> render_inertia("control-panel/App")
  end

  defp swagger_ui_path do
    case Application.get_env(:bullx, :dev_routes, false) do
      true -> "/dev/swaggerui"
      false -> nil
    end
  end

  defp user_props(%User{} = user) do
    %{
      id: user.id,
      display_name: user.display_name,
      email: user.email
    }
  end
end
