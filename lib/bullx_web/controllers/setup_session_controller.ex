defmodule BullXWeb.SetupSessionController do
  use BullXWeb, :controller

  require Logger

  @session_key :bootstrap_activation_code_hash
  @config_key "bullx.i18n_default_locale"

  def new(conn, _params) do
    case BullXAccounts.setup_required?() do
      true -> render_gate(conn)
      false -> redirect(conn, to: ~p"/")
    end
  end

  def create(conn, params) do
    cond do
      not BullXAccounts.setup_required?() ->
        redirect(conn, to: ~p"/")

      true ->
        params
        |> bootstrap_code_from_params()
        |> verify_and_sign_in(conn, locale_from_params(params))
    end
  end

  defp render_gate(conn) do
    conn
    |> assign(:page_title, "Setup")
    |> assign_prop(:form_action, ~p"/setup/sessions")
    |> assign_prop(:current_locale, BullXWeb.I18n.HTML.lang())
    |> assign_prop(:available_locales, available_locale_strings())
    |> render_inertia("setup/sessions/New")
  end

  defp verify_and_sign_in(:error, conn, _locale), do: invalid_code(conn)

  defp verify_and_sign_in({:ok, plaintext}, conn, locale) do
    case BullXAccounts.verify_bootstrap_activation_code(plaintext) do
      {:ok, code_hash} ->
        maybe_apply_locale(locale)

        conn
        |> put_session(@session_key, code_hash)
        |> redirect(to: ~p"/setup")

      {:error, :invalid_or_expired_code} ->
        invalid_code(conn)
    end
  end

  defp invalid_code(conn) do
    conn
    |> put_flash(:error, BullX.I18n.t("setup.bootstrap.activation_code_invalid"))
    |> redirect(to: ~p"/setup/sessions/new")
  end

  defp bootstrap_code_from_params(%{"setup" => %{"bootstrap_code" => code}}),
    do: normalize_code(code)

  defp bootstrap_code_from_params(%{"bootstrap_code" => code}), do: normalize_code(code)
  defp bootstrap_code_from_params(_params), do: :error

  defp locale_from_params(%{"setup" => %{"locale" => locale}}), do: normalize_locale(locale)
  defp locale_from_params(%{"locale" => locale}), do: normalize_locale(locale)
  defp locale_from_params(_params), do: :invalid

  defp normalize_code(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> :error
      code -> {:ok, code}
    end
  end

  defp normalize_code(_value), do: :error

  defp normalize_locale(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :invalid
      locale -> {:ok, locale}
    end
  end

  defp normalize_locale(_value), do: :invalid

  defp maybe_apply_locale(:invalid) do
    Logger.warning(
      "Setup gate ignoring blank or missing locale; available locales: #{inspect(available_locale_strings())}"
    )

    :ok
  end

  defp maybe_apply_locale({:ok, locale}) when is_binary(locale) do
    case locale in available_locale_strings() do
      true ->
        BullX.Config.put(@config_key, locale)
        BullX.I18n.reload()
        :ok

      false ->
        Logger.warning(
          "Setup gate ignoring unsupported locale #{inspect(locale)}; available locales: #{inspect(available_locale_strings())}"
        )

        :ok
    end
  end

  defp available_locale_strings do
    BullX.I18n.available_locales()
    |> Enum.map(&Atom.to_string/1)
  end
end
