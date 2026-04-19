defmodule BullXWeb.PageController do
  use BullXWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
