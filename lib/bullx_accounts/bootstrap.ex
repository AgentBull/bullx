defmodule BullXAccounts.Bootstrap do
  @moduledoc false

  use Task

  import Ecto.Query

  require Logger

  alias BullX.Repo
  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:restart, :transient)
  end

  def run do
    case authn_tables_ready?() do
      true -> maybe_create_bootstrap_activation_code()
      false -> Logger.warning("BullXAccounts bootstrap skipped because AuthN tables do not exist")
    end
  end

  defp maybe_create_bootstrap_activation_code do
    case {users_empty?(), valid_activation_code_exists?()} do
      {true, false} ->
        create_and_log_bootstrap_activation_code()

      _ready_or_code_exists ->
        :ok
    end
  end

  defp create_and_log_bootstrap_activation_code do
    case BullXAccounts.create_activation_code(nil, %{source: "bootstrap"}) do
      {:ok, %{code: code}} ->
        Logger.warning("BullX bootstrap activation code: #{code}")

      {:error, reason} ->
        Logger.warning(
          "BullXAccounts bootstrap activation code creation failed: #{inspect(reason)}"
        )
    end
  end

  defp users_empty?, do: not Repo.exists?(from user in User, select: 1)

  defp valid_activation_code_exists? do
    now = DateTime.utc_now()

    Repo.exists?(
      from code in ActivationCode,
        where: is_nil(code.revoked_at) and is_nil(code.used_at) and code.expires_at > ^now,
        select: 1
    )
  end

  defp authn_tables_ready? do
    query = """
    SELECT
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'users'
      ),
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'activation_codes'
      )
    """

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, %{rows: [[users, activation_codes]]}} -> users and activation_codes
      {:error, reason} -> log_table_check_error(reason)
    end
  end

  defp log_table_check_error(reason) do
    Logger.warning("BullXAccounts bootstrap table check failed: #{inspect(reason)}")
    false
  end
end
