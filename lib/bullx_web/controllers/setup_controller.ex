defmodule BullXWeb.SetupController do
  use BullXWeb, :controller

  alias BullXGateway.{AdapterConfig, AdapterSupervisor}

  @catalog BullXAIAgent.LLM.Catalog
  @session_key :bootstrap_activation_code_hash

  def show(conn, _params) do
    cond do
      not BullXAccounts.setup_required?() -> redirect(conn, to: ~p"/")
      not authenticated_for_setup?(conn) -> drop_session_and_redirect_to_gate(conn)
      not llm_configured?() -> redirect(conn, to: ~p"/setup/llm")
      not gateway_configured?() -> redirect(conn, to: "/setup/gateway")
      true -> redirect(conn, to: ~p"/setup/activate-owner")
    end
  end

  def activate_owner(conn, _params) do
    cond do
      not BullXAccounts.setup_required?() -> redirect(conn, to: ~p"/")
      authenticated_for_setup?(conn) -> maybe_render_owner_activation_instructions(conn)
      true -> drop_session_and_redirect_to_gate(conn)
    end
  end

  def activation_status(conn, _params) do
    case BullXAccounts.setup_required?() do
      true ->
        json(conn, %{activated: false})

      false ->
        conn
        |> delete_session(@session_key)
        |> json(%{activated: true, redirect_to: ~p"/"})
    end
  end

  defp authenticated_for_setup?(conn) do
    BullXAccounts.bootstrap_activation_code_valid_for_hash?(get_session(conn, @session_key))
  end

  defp drop_session_and_redirect_to_gate(conn) do
    conn
    |> delete_session(@session_key)
    |> redirect(to: ~p"/setup/sessions/new")
  end

  defp llm_configured? do
    apply(@catalog, :default_alias_configured?, [])
  end

  defp gateway_configured? do
    runtime_gateway_specs()
    |> configured_runtime_specs?()
  end

  defp runtime_gateway_specs do
    AdapterConfig.existing_entries()
    |> Enum.filter(&Map.get(&1, "enabled", true))
    |> AdapterConfig.runtime_specs()
  end

  defp configured_runtime_specs?({:ok, [_ | _]}), do: true
  defp configured_runtime_specs?(_result), do: false

  defp maybe_render_owner_activation_instructions(conn) do
    with {:ok, [_ | _] = specs} <- runtime_gateway_specs(),
         :ok <- AdapterSupervisor.reconcile_configured_channels(specs) do
      render_owner_activation_instructions(conn)
    else
      _reason -> redirect(conn, to: "/setup/gateway")
    end
  end

  defp render_owner_activation_instructions(conn) do
    conn
    |> assign(:page_title, "Setup")
    |> assign_prop(:app_name, "BullX")
    |> assign_prop(:command, "/preauth <activation-code>")
    |> assign_prop(:back_path, ~p"/setup/gateway")
    |> assign_prop(:status_path, ~p"/setup/activate-owner/status")
    |> render_inertia("setup/ActivateOwner")
  end
end
