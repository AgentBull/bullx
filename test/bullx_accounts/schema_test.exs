defmodule BullXAccounts.SchemaTest do
  use BullX.DataCase, async: false

  alias BullXAccounts.User
  alias BullXAccounts.UserChannelBinding

  test "users use application-generated UUID primary keys" do
    user = insert_user!(display_name: "Alice")

    assert {:ok, _uuid} = Ecto.UUID.cast(user.id)
  end

  test "unique user fields allow many null values and reject duplicate non-null values" do
    insert_user!(display_name: "Alice")
    insert_user!(display_name: "Bob")
    insert_user!(display_name: "Carol", email: "user@example.com")

    assert {:error, changeset} =
             %User{}
             |> User.changeset(%{display_name: "Duplicate", email: "user@example.com"})
             |> Repo.insert()

    assert %{email: [_message]} = errors_on(changeset)
  end

  test "status is persisted as the native user_status PostgreSQL enum" do
    user = insert_user!(display_name: "Alice", status: :banned)

    assert user.status == :banned
    assert Repo.reload!(user).status == :banned

    assert {:error, %Ecto.Changeset{}} =
             %User{}
             |> User.changeset(%{display_name: "Invalid", status: "not_a_state"})
             |> Repo.insert()
  end

  test "email must look like an email address" do
    assert {:error, changeset} =
             %User{}
             |> User.changeset(%{display_name: "Bad", email: "not-an-email"})
             |> Repo.insert()

    assert %{email: [_message]} = errors_on(changeset)
  end

  test "phone is validated and normalized to canonical E.164" do
    {:ok, user} =
      %User{}
      |> User.changeset(%{display_name: "Alice", phone: "+1 415 555 2671"})
      |> Repo.insert()

    assert user.phone == "+14155552671"

    assert {:error, changeset} =
             %User{}
             |> User.changeset(%{display_name: "Bad", phone: "13800138000"})
             |> Repo.insert()

    assert %{phone: [_message]} = errors_on(changeset)
  end

  test "channel actor binding key is unique" do
    user = insert_user!(display_name: "Alice")

    insert_binding!(user,
      adapter: "feishu",
      channel_id: "workplace-main",
      external_id: "ou_1"
    )

    assert {:error, changeset} =
             %UserChannelBinding{}
             |> UserChannelBinding.changeset(%{
               user_id: user.id,
               adapter: "feishu",
               channel_id: "workplace-main",
               external_id: "ou_1",
               metadata: %{}
             })
             |> Repo.insert()

    assert %{adapter: [_message]} = errors_on(changeset)
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp insert_binding!(user, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:user_id, user.id)
      |> Map.put_new(:metadata, %{})

    %UserChannelBinding{}
    |> UserChannelBinding.changeset(attrs)
    |> Repo.insert!()
  end
end
