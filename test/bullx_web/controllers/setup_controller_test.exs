defmodule BullXWeb.SetupControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullX.Config.AppConfig
  alias BullXGateway.{AdapterConfig, AdapterSupervisor}
  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User

  @gateway_config_key "bullx.gateway.adapters"
  @llm_cache BullXAIAgent.LLM.Catalog.Cache
  @llm_writer BullXAIAgent.LLM.Writer

  setup do
    allow_llm_cache()
    previous_gateway_config = Repo.get(AppConfig, @gateway_config_key)

    on_exit(fn ->
      AdapterSupervisor.stop_channel({:feishu, "ops-main"})

      case previous_gateway_config do
        nil -> BullX.Config.delete(@gateway_config_key)
        %AppConfig{value: value} -> BullX.Config.put(@gateway_config_key, value)
      end

      AdapterSupervisor.reconcile_configured_channels(BullX.Config.Gateway.adapters())
      refresh_llm_cache()
    end)

    BullX.Config.delete(@gateway_config_key)
    refresh_llm_cache()

    :ok
  end

  test "GET /setup redirects to the gate when no bootstrap hash is in the session", %{conn: conn} do
    Repo.delete_all(ActivationCode)
    {:ok, _result} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/setup/sessions/new"
  end

  test "GET /setup redirects to LLM setup when default alias is unbound", %{
    conn: conn
  } do
    conn =
      conn
      |> setup_session()
      |> get(~p"/setup")

    assert redirected_to(conn) == ~p"/setup/llm"
  end

  test "GET /setup redirects to gateway setup when LLM is configured and no adapter is enabled",
       %{
         conn: conn
       } do
    put_default_llm_provider!()

    conn =
      conn
      |> setup_session()
      |> get(~p"/setup")

    assert redirected_to(conn) == "/setup/gateway"
  end

  test "GET /setup redirects to owner activation when LLM and gateway are configured", %{
    conn: conn
  } do
    put_default_llm_provider!()
    put_gateway_adapter!()

    conn =
      conn
      |> setup_session()
      |> get(~p"/setup")

    assert redirected_to(conn) == ~p"/setup/activate-owner"
  end

  test "GET /setup drops a stale bootstrap hash and redirects to the gate", %{conn: conn} do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    {:ok, stale_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)

    Repo.delete_all(ActivationCode)

    conn =
      conn
      |> init_test_session(%{bootstrap_activation_code_hash: stale_hash})
      |> get(~p"/setup")

    assert redirected_to(conn) == ~p"/setup/sessions/new"
    assert get_session(conn, :bootstrap_activation_code_hash) == nil
  end

  test "GET /setup redirects home once a user exists", %{conn: conn} do
    insert_user!(display_name: "Alice")

    conn = get(conn, ~p"/setup")

    assert redirected_to(conn) == ~p"/"
  end

  test "GET /setup/activate-owner renders the activate-owner SPA for a valid setup session", %{
    conn: conn
  } do
    put_gateway_adapter!()

    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)

    conn =
      conn
      |> init_test_session(%{bootstrap_activation_code_hash: code_hash})
      |> get(~p"/setup/activate-owner")

    response = html_response(conn, 200)

    assert response =~ "setup/ActivateOwner"
    assert response =~ "preauth"
    assert response =~ "/setup/activate-owner/status"
    refute response =~ plaintext
    assert is_pid(AdapterSupervisor.whereis_channel({:feishu, "ops-main"}))
  end

  test "GET /setup/activate-owner redirects to gateway setup when no adapter is enabled", %{
    conn: conn
  } do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)

    conn =
      conn
      |> init_test_session(%{bootstrap_activation_code_hash: code_hash})
      |> get(~p"/setup/activate-owner")

    assert redirected_to(conn) == "/setup/gateway"
  end

  test "GET /setup/activate-owner/status returns activated:false while setup is required",
       %{conn: conn} do
    Repo.delete_all(ActivationCode)
    {:ok, _result} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    conn = get(conn, ~p"/setup/activate-owner/status")

    assert json_response(conn, 200) == %{"activated" => false}
  end

  test "GET /setup/activate-owner/status returns activated:true and clears bootstrap session once setup is complete",
       %{conn: conn} do
    insert_user!(display_name: "Owner")

    conn =
      conn
      |> init_test_session(%{bootstrap_activation_code_hash: "stale-hash"})
      |> get(~p"/setup/activate-owner/status")

    assert json_response(conn, 200) == %{"activated" => true, "redirect_to" => "/"}
    assert get_session(conn, :bootstrap_activation_code_hash) == nil
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp setup_session(conn) do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)
    init_test_session(conn, %{bootstrap_activation_code_hash: code_hash})
  end

  defp put_default_llm_provider! do
    {:ok, _provider} =
      apply(@llm_writer, :put_provider, [
        %{
          name: "primary",
          provider_id: "openai",
          model_id: "gpt-4o-mini",
          provider_options: %{}
        }
      ])

    {:ok, _binding} = apply(@llm_writer, :put_alias_binding, [:default, {:provider, "primary"}])
  end

  defp put_gateway_adapter! do
    {:ok, encoded, _entries} = AdapterConfig.encode_for_storage([feishu_entry()])
    :ok = BullX.Config.put(@gateway_config_key, encoded)
  end

  defp feishu_entry do
    %{
      "id" => "feishu:ops-main",
      "adapter" => "feishu",
      "channel_id" => "ops-main",
      "enabled" => true,
      "domain" => "feishu",
      "credentials" => %{
        "app_id" => "cli_test",
        "app_secret" => "secret_test"
      }
    }
  end

  defp allow_llm_cache do
    case Process.whereis(@llm_cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end

  defp refresh_llm_cache do
    case function_exported?(@llm_cache, :refresh_all, 0) do
      true -> apply(@llm_cache, :refresh_all, [])
      false -> :ok
    end
  end
end
