defmodule BullXAccounts.AuthZ.Bootstrap do
  @moduledoc false

  use Task

  require Logger

  alias BullX.Repo
  alias BullXAccounts.UserGroup

  @admin_group_name "admin"

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:restart, :transient)
  end

  def run do
    case authz_tables_ready?() do
      true ->
        ensure_admin_group()

      false ->
        Logger.warning("BullXAccounts.AuthZ bootstrap skipped because AuthZ tables do not exist")
    end
  end

  defp ensure_admin_group do
    case Repo.get_by(UserGroup, name: @admin_group_name) do
      nil -> create_admin_group()
      %UserGroup{type: :static, built_in: true} -> :ok
      group -> log_conflicting_admin_group(group)
    end
  end

  defp create_admin_group do
    attrs = %{
      name: @admin_group_name,
      type: :static,
      description: "Built-in administrators group.",
      built_in: true
    }

    case %UserGroup{}
         |> UserGroup.system_create_changeset(attrs)
         |> Repo.insert() do
      {:ok, _group} ->
        Logger.info("BullXAccounts.AuthZ bootstrap created built-in admin group")

      {:error, changeset} ->
        Logger.warning(
          "BullXAccounts.AuthZ bootstrap failed to create admin group: #{inspect(changeset.errors)}"
        )
    end
  end

  defp log_conflicting_admin_group(%UserGroup{} = group) do
    Logger.warning(
      "BullXAccounts.AuthZ bootstrap found conflicting admin group: #{inspect(Map.take(group, [:id, :type, :built_in]))}"
    )
  end

  defp authz_tables_ready? do
    query = """
    SELECT
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'user_groups'
      ),
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'permission_grants'
      )
    """

    case Ecto.Adapters.SQL.query(Repo, query, []) do
      {:ok, %{rows: [[user_groups, permission_grants]]}} -> user_groups and permission_grants
      {:error, reason} -> log_table_check_error(reason)
    end
  end

  defp log_table_check_error(reason) do
    Logger.warning("BullXAccounts.AuthZ bootstrap table check failed: #{inspect(reason)}")
    false
  end
end
