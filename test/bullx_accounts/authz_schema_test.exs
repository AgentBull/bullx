defmodule BullXAccounts.AuthZSchemaTest do
  use BullX.DataCase, async: false

  alias BullXAccounts.User

  test "AuthZ primary keys are application-generated UUIDv7 values" do
    {:ok, group} =
      BullXAccounts.create_user_group(%{name: "engineers", type: :static})

    assert {:ok, _uuid} = Ecto.UUID.cast(group.id)

    user = insert_user!(display_name: "Alice")

    {:ok, grant} =
      BullXAccounts.create_permission_grant(%{
        user_id: user.id,
        resource_pattern: "web_console",
        action: "read"
      })

    assert {:ok, _uuid} = Ecto.UUID.cast(grant.id)
  end

  test "user_group_type is a native PostgreSQL enum" do
    {:ok, %{rows: [[type_kind]]}} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT typtype FROM pg_type WHERE typname = 'user_group_type'
        """,
        []
      )

    assert type_kind == "e"
  end

  test "static groups must not carry computed_expression" do
    assert {:error, changeset} =
             BullXAccounts.create_user_group(%{
               name: "bad-static",
               type: :static,
               computed_expression: %{"op" => "user_status", "eq" => "active"}
             })

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()
  end

  test "computed groups must carry a valid computed_expression" do
    assert {:error, changeset} =
             BullXAccounts.create_user_group(%{name: "bad-computed", type: :computed})

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()

    assert {:ok, group} =
             BullXAccounts.create_user_group(%{
               name: "active-users",
               type: :computed,
               computed_expression: %{"op" => "user_status", "eq" => "active"}
             })

    assert group.type == :computed
  end

  test "user_group_memberships has a composite primary key on {user_id, group_id}" do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = 'user_group_memberships'::regclass AND i.indisprimary
        ORDER BY a.attname
        """,
        []
      )

    assert Enum.sort(List.flatten(rows)) == ["group_id", "user_id"]
  end

  test "group name and type are immutable after creation" do
    {:ok, group} = BullXAccounts.create_user_group(%{name: "team-a", type: :static})

    {:ok, updated} = BullXAccounts.update_user_group(group, %{name: "team-b", type: :computed})

    assert updated.name == "team-a"
    assert updated.type == :static
  end

  test "group updates validate type and expression invariants as changeset errors" do
    {:ok, static} = BullXAccounts.create_user_group(%{name: "static-team", type: :static})

    assert {:error, changeset} =
             BullXAccounts.update_user_group(static, %{
               computed_expression: %{"op" => "user_status", "eq" => "active"}
             })

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()

    {:ok, computed} =
      BullXAccounts.create_user_group(%{
        name: "computed-team",
        type: :computed,
        computed_expression: %{"op" => "user_status", "eq" => "active"}
      })

    assert {:error, changeset} =
             BullXAccounts.update_user_group(computed, %{computed_expression: nil})

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()
  end

  test "computed group updates reject cycles" do
    {:ok, a} =
      BullXAccounts.create_user_group(%{
        name: "cycle-a",
        type: :computed,
        computed_expression: %{"op" => "user_status", "eq" => "active"}
      })

    {:ok, _b} =
      BullXAccounts.create_user_group(%{
        name: "cycle-b",
        type: :computed,
        computed_expression: %{"op" => "group_member", "group" => "cycle-a"}
      })

    assert {:error, changeset} =
             BullXAccounts.update_user_group(a, %{
               computed_expression: %{"op" => "group_member", "group" => "cycle-b"}
             })

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()
  end

  test "public create/update changesets cannot set or clear built_in" do
    {:ok, group} =
      BullXAccounts.create_user_group(%{name: "team-c", type: :static, built_in: true})

    assert group.built_in == false

    {:ok, updated} = BullXAccounts.update_user_group(group, %{built_in: true})
    assert updated.built_in == false
  end

  test "static group memberships table rejects computed group writes via public API" do
    user = insert_user!(display_name: "Alice")

    {:ok, group} =
      BullXAccounts.create_user_group(%{
        name: "computed-managers",
        type: :computed,
        computed_expression: %{"op" => "user_status", "eq" => "active"}
      })

    assert {:error, :computed_group} = BullXAccounts.add_user_to_group(user, group)
  end

  test "permission grants require exactly one of user_id or group_id" do
    user = insert_user!(display_name: "Alice")

    {:ok, group} = BullXAccounts.create_user_group(%{name: "engineers", type: :static})

    assert {:error, changeset} =
             BullXAccounts.create_permission_grant(%{
               resource_pattern: "web_console",
               action: "read"
             })

    assert errors_on(changeset)[:user_id] |> Enum.any?()

    assert {:error, changeset} =
             BullXAccounts.create_permission_grant(%{
               user_id: user.id,
               group_id: group.id,
               resource_pattern: "web_console",
               action: "read"
             })

    assert errors_on(changeset)[:user_id] |> Enum.any?()
  end

  test "permission grant patterns accept at most one wildcard" do
    user = insert_user!(display_name: "Alice")

    assert {:error, changeset} =
             BullXAccounts.create_permission_grant(%{
               user_id: user.id,
               resource_pattern: "gateway:*:*",
               action: "read"
             })

    assert errors_on(changeset)[:resource_pattern] |> Enum.any?()
  end

  test "permission grant actions cannot contain ':'" do
    user = insert_user!(display_name: "Alice")

    assert {:error, changeset} =
             BullXAccounts.create_permission_grant(%{
               user_id: user.id,
               resource_pattern: "web_console",
               action: "read:more"
             })

    assert errors_on(changeset)[:action] |> Enum.any?()
  end

  test "permission grant condition is validated through Cedar" do
    user = insert_user!(display_name: "Alice")

    assert {:error, changeset} =
             BullXAccounts.create_permission_grant(%{
               user_id: user.id,
               resource_pattern: "web_console",
               action: "read",
               condition: ""
             })

    assert errors_on(changeset)[:condition] |> Enum.any?()

    assert {:error, changeset} =
             BullXAccounts.create_permission_grant(%{
               user_id: user.id,
               resource_pattern: "web_console",
               action: "read",
               condition: "this is not a cedar expression"
             })

    assert errors_on(changeset)[:condition] |> Enum.any?()

    assert {:ok, _grant} =
             BullXAccounts.create_permission_grant(%{
               user_id: user.id,
               resource_pattern: "web_console",
               action: "read",
               condition: "true"
             })
  end

  test "permission grant updates validate the final persisted condition" do
    user = insert_user!(display_name: "Alice")

    {:ok, grant} =
      BullXAccounts.create_permission_grant(%{
        user_id: user.id,
        resource_pattern: "web_console",
        action: "read",
        condition: "true"
      })

    Repo.update_all(
      from(g in BullXAccounts.PermissionGrant, where: g.id == ^grant.id),
      set: [condition: "not valid cedar"]
    )

    invalid_grant = Repo.get!(BullXAccounts.PermissionGrant, grant.id)

    assert {:error, changeset} =
             BullXAccounts.update_permission_grant(invalid_grant, %{description: "touch"})

    assert errors_on(changeset)[:condition] |> Enum.any?()
  end

  test "computed groups reject malformed expressions and unknown group references" do
    assert {:error, changeset} =
             BullXAccounts.create_user_group(%{
               name: "broken",
               type: :computed,
               computed_expression: %{"op" => "and", "args" => []}
             })

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()

    assert {:error, changeset} =
             BullXAccounts.create_user_group(%{
               name: "ghost-ref",
               type: :computed,
               computed_expression: %{"op" => "group_member", "group" => "does-not-exist"}
             })

    assert errors_on(changeset)[:computed_expression] |> Enum.any?()
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end
end
