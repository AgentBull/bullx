defmodule BullXWeb.FeishuAuthController do
  use BullXWeb, :controller

  def new(conn, params) do
    case BullXFeishu.SSO.authorization_url(params) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, BullX.I18n.t("gateway.feishu.auth.web_auth_failed"))
        |> redirect(to: ~p"/sessions/new")
    end
  end

  def callback(conn, params) do
    case BullXFeishu.SSO.login_from_callback(params) do
      {:ok, %{user: user, return_to: return_to}} ->
        Plug.CSRFProtection.delete_csrf_token()

        conn
        |> renew_session()
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: return_to)

      {:error, :not_bound} ->
        login_failed(conn, BullX.I18n.t("gateway.feishu.auth.login_not_bound"))

      {:error, :user_banned} ->
        login_failed(conn, BullX.I18n.t("gateway.feishu.auth.denied"))

      {:error, _reason} ->
        login_failed(conn, BullX.I18n.t("gateway.feishu.auth.web_auth_failed"))
    end
  end

  defp login_failed(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sessions/new")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
