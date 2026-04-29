defmodule BullXAccounts.Bootstrap do
  @moduledoc false

  use Task

  require Logger

  alias BullX.Repo

  @bootstrap_activation_banner_line String.duplicate("=", 80)

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:restart, :transient)
  end

  def run do
    case authn_tables_ready?() do
      true -> maybe_create_or_refresh_bootstrap_activation_code()
      false -> Logger.warning("BullXAccounts bootstrap skipped because AuthN tables do not exist")
    end
  end

  defp maybe_create_or_refresh_bootstrap_activation_code do
    cond do
      not BullXAccounts.setup_required?() -> :ok
      BullXAccounts.bootstrap_activation_code_consumed?() -> :ok
      true -> create_or_refresh_and_log()
    end
  end

  defp create_or_refresh_and_log do
    case BullXAccounts.create_or_refresh_bootstrap_activation_code() do
      {:ok, %{code: code, action: action}} when action in [:created, :refreshed] ->
        log_bootstrap_activation_code(code, action)

      {:error, reason} when reason in [:bootstrap_not_required, :bootstrap_already_consumed] ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BullXAccounts bootstrap activation code creation failed: #{inspect(reason)}"
        )
    end
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

  defp log_bootstrap_activation_code(code, action) do
    Logger.warning(
      IO.iodata_to_binary([
        "\n\n",
        @bootstrap_activation_banner_line,
        "\n BullX bootstrap activation code (",
        Atom.to_string(action),
        "): ",
        code,
        "\n",
        @bootstrap_activation_banner_line,
        "\n\n"
      ])
    )
  end
end
