defmodule BullXAccounts.AuthNTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User
  alias BullXAccounts.UserChannelAuthCode
  alias BullXAccounts.UserChannelBinding

  setup do
    previous = Application.get_env(:bullx, :accounts)

    put_accounts_config()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bullx, :accounts)
        value -> Application.put_env(:bullx, :accounts, value)
      end
    end)

    :ok
  end

  test "active bound users resolve successfully" do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")

    assert {:ok, resolved} = BullXAccounts.resolve_channel_actor(:feishu, "main", "ou_1")
    assert resolved.id == user.id
  end

  test "nil and boolean channel identifiers are rejected instead of persisted as strings" do
    for value <- [nil, true, false] do
      assert {:error, :invalid_identifier} =
               BullXAccounts.resolve_channel_actor(:feishu, "main", value)

      assert {:error, :invalid_identifier} =
               BullXAccounts.match_or_create_from_channel(%{
                 adapter: :feishu,
                 channel_id: "main",
                 external_id: value,
                 profile: %{"display_name" => "Bad Identifier"}
               })
    end

    refute Repo.exists?(
             from binding in UserChannelBinding,
               where: binding.external_id in ["nil", "true", "false"]
           )
  end

  test "banned users fail channel resolution and web auth-code issuance" do
    user = insert_user!(display_name: "Alice", status: :banned)
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")

    assert {:error, :user_banned} = BullXAccounts.resolve_channel_actor(:feishu, "main", "ou_1")

    assert {:error, :user_banned} =
             BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")
  end

  test "matching rules short-circuit in configured order" do
    email_user = insert_user!(display_name: "Email User", email: "alice@example.com")
    phone_user = insert_user!(display_name: "Phone User", phone: "+8613800138000")

    put_accounts_config(
      authn_match_rules: [
        %{
          result: "bind_existing_user",
          op: "equals_user_field",
          source_path: "profile.phone",
          user_field: "phone"
        },
        %{
          result: "bind_existing_user",
          op: "equals_user_field",
          source_path: "profile.email",
          user_field: "email"
        }
      ]
    )

    assert {:ok, user, binding} =
             BullXAccounts.match_or_create_from_channel(%{
               adapter: :feishu,
               channel_id: "main",
               external_id: "ou_2",
               profile: %{
                 "email" => email_user.email,
                 "phone" => phone_user.phone,
                 "display_name" => "Alice"
               }
             })

    assert user.id == phone_user.id
    assert binding.user_id == phone_user.id
  end

  test "phone matching uses the same E.164 canonical form as stored users" do
    user = insert_user!(display_name: "Phone User", phone: "+14155552671")

    put_accounts_config(
      authn_match_rules: [
        %{
          result: "bind_existing_user",
          op: "equals_user_field",
          source_path: "profile.phone",
          user_field: "phone"
        }
      ]
    )

    assert {:ok, resolved, binding} =
             BullXAccounts.match_or_create_from_channel(
               channel_input("ou_phone", profile: %{"phone" => "+1 415 555 2671"})
             )

    assert resolved.id == user.id
    assert binding.user_id == user.id
  end

  test "bind_existing_user matching a banned user halts with :user_banned" do
    insert_user!(display_name: "Banned", email: "banned@example.com", status: :banned)

    put_accounts_config(
      authn_match_rules: [
        %{
          result: "bind_existing_user",
          op: "equals_user_field",
          source_path: "profile.email",
          user_field: "email"
        }
      ]
    )

    assert {:error, :user_banned} =
             BullXAccounts.match_or_create_from_channel(
               channel_input("ou_banned", profile: %{"email" => "banned@example.com"})
             )
  end

  test "allow_create_user rules create a user and first binding when auto-creation is enabled" do
    put_accounts_config(
      authn_match_rules: [
        %{
          "result" => "allow_create_user",
          "op" => "email_domain_in",
          "source_path" => "profile.email",
          "domains" => ["example.com"]
        }
      ]
    )

    assert {:ok, user, binding} =
             BullXAccounts.match_or_create_from_channel(%{
               adapter: "feishu",
               channel_id: "main",
               external_id: "ou_3",
               profile: %{"email" => "new@example.com", "display_name" => "New User"}
             })

    assert user.email == "new@example.com"
    assert binding.user_id == user.id
  end

  test "concurrent first contact for the same actor resolves to one binding" do
    put_accounts_config(authn_auto_create_users: true, authn_require_activation_code: false)

    input = %{
      adapter: :feishu,
      channel_id: "main",
      external_id: "ou_same_actor",
      profile: %{"display_name" => "Same Actor"}
    }

    test_pid = self()

    tasks =
      for _i <- 1..8 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
          BullXAccounts.match_or_create_from_channel(input)
        end)
      end

    results = Enum.map(tasks, &Task.await/1)

    assert Enum.all?(results, &match?({:ok, _user, _binding}, &1))

    binding_ids =
      results
      |> Enum.map(fn {:ok, _user, binding} -> binding.id end)
      |> Enum.uniq()

    assert length(binding_ids) == 1

    assert Repo.aggregate(
             from(binding in UserChannelBinding,
               where:
                 binding.adapter == "feishu" and binding.channel_id == "main" and
                   binding.external_id == "ou_same_actor"
             ),
             :count
           ) == 1
  end

  test "auto_create_users=false returns :activation_required for both rule-matched and unmatched flows" do
    put_accounts_config(
      authn_auto_create_users: false,
      authn_match_rules: [
        %{
          "result" => "allow_create_user",
          "op" => "email_domain_in",
          "source_path" => "profile.email",
          "domains" => ["example.com"]
        }
      ]
    )

    assert {:error, :activation_required} =
             BullXAccounts.match_or_create_from_channel(
               channel_input("ou_disabled_match", profile: %{"email" => "new@example.com"})
             )

    assert {:error, :activation_required} =
             BullXAccounts.match_or_create_from_channel(channel_input("ou_disabled_unmatched"))
  end

  test "required activation returns activation_required when no automatic rule matches" do
    assert {:error, :activation_required} =
             BullXAccounts.match_or_create_from_channel(channel_input("ou_activation"))
  end

  test "activation code consumption creates a new user and first binding once" do
    assert {:ok, %{code: code, activation_code: activation_code}} =
             BullXAccounts.create_activation_code(nil, %{reason: "test"})

    assert activation_code.code_hash != code

    input = channel_input("ou_preauth")

    assert {:ok, user, binding} = BullXAccounts.consume_activation_code(code, input)
    assert user.display_name == "User ou_preauth"
    assert binding.user_id == user.id

    used_code = Repo.get!(ActivationCode, activation_code.id)
    assert used_code.used_at
    assert used_code.used_by_adapter == "feishu"

    assert {:error, :already_bound} = BullXAccounts.consume_activation_code(code, input)
  end

  test "activation code consumption uses automatic matching without consuming the code" do
    user = insert_user!(display_name: "Alice", email: "alice@example.com")

    put_accounts_config(
      authn_match_rules: [
        %{
          result: "bind_existing_user",
          op: "equals_user_field",
          source_path: "profile.email",
          user_field: "email"
        }
      ]
    )

    assert {:ok, %{code: code, activation_code: activation_code}} =
             BullXAccounts.create_activation_code(nil, %{})

    assert {:ok, resolved, binding} =
             BullXAccounts.consume_activation_code(
               code,
               channel_input("ou_match", profile: %{"email" => user.email})
             )

    assert resolved.id == user.id
    assert binding.user_id == user.id
    assert Repo.get!(ActivationCode, activation_code.id).used_at == nil
  end

  test "activation code still works when auto_create_users=false" do
    put_accounts_config(authn_auto_create_users: false)

    assert {:ok, %{code: code}} = BullXAccounts.create_activation_code(nil, %{})

    assert {:ok, user, binding} =
             BullXAccounts.consume_activation_code(code, channel_input("ou_auto_off"))

    assert user.display_name == "User ou_auto_off"
    assert binding.user_id == user.id
  end

  test "revoked activation code cannot be consumed" do
    assert {:ok, %{code: code, activation_code: activation_code}} =
             BullXAccounts.create_activation_code(nil, %{})

    assert {:ok, revoked} = BullXAccounts.revoke_activation_code(activation_code)
    assert revoked.revoked_at

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.consume_activation_code(code, channel_input("ou_revoked"))
  end

  test "expired activation code cannot be consumed" do
    assert {:ok, %{code: code, activation_code: activation_code}} =
             BullXAccounts.create_activation_code(nil, %{})

    past =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(c in ActivationCode, where: c.id == ^activation_code.id),
      set: [expires_at: past]
    )

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.consume_activation_code(code, channel_input("ou_expired"))
  end

  test "concurrent consumption of the same activation code succeeds exactly once" do
    assert {:ok, %{code: code}} = BullXAccounts.create_activation_code(nil, %{})

    test_pid = self()

    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())

          BullXAccounts.consume_activation_code(
            code,
            channel_input("ou_concurrent_#{i}")
          )
        end)
      end

    results = Enum.map(tasks, &Task.await/1)

    successes = Enum.count(results, &match?({:ok, _user, _binding}, &1))
    failures = Enum.count(results, &match?({:error, :invalid_or_expired_code}, &1))

    assert successes == 1
    assert successes + failures == length(results)
  end

  test "user channel auth codes are deleted on successful consumption" do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")

    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")
    assert Repo.aggregate(UserChannelAuthCode, :count) == 1

    assert {:ok, resolved} = BullXAccounts.consume_user_channel_auth_code(code)
    assert resolved.id == user.id
    assert Repo.aggregate(UserChannelAuthCode, :count) == 0

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.consume_user_channel_auth_code(code)
  end

  test "user channel auth codes expire by configured TTL" do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    put_accounts_config(web_auth_code_ttl_seconds: 1)

    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    expired_at =
      DateTime.utc_now()
      |> DateTime.add(-10, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(UserChannelAuthCode, set: [inserted_at: expired_at, updated_at: expired_at])

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.consume_user_channel_auth_code(code)
  end

  test "provider login binds to an existing user when a bind_existing_user rule matches" do
    user = insert_user!(display_name: "Alice", email: "alice@example.com")

    put_accounts_config(
      authn_match_rules: [
        %{
          result: "bind_existing_user",
          op: "equals_user_field",
          source_path: "profile.email",
          user_field: "email"
        }
      ]
    )

    assert {:ok, resolved, binding} =
             BullXAccounts.login_from_provider(
               channel_input("ou_provider_bind", profile: %{"email" => user.email})
             )

    assert resolved.id == user.id
    assert binding.user_id == user.id
  end

  test "provider login creates a new user when an allow_create_user rule matches" do
    put_accounts_config(
      authn_match_rules: [
        %{
          "result" => "allow_create_user",
          "op" => "email_domain_in",
          "source_path" => "profile.email",
          "domains" => ["example.com"]
        }
      ]
    )

    assert {:ok, user, binding} =
             BullXAccounts.login_from_provider(
               channel_input("ou_provider_create", profile: %{"email" => "fresh@example.com"})
             )

    assert user.email == "fresh@example.com"
    assert binding.user_id == user.id
  end

  test "provider login does not establish a user when activation would be required" do
    assert {:error, :not_bound} = BullXAccounts.login_from_provider(channel_input("ou_provider"))
  end

  test "provider login does not use unmatched channel auto-creation" do
    put_accounts_config(authn_auto_create_users: true, authn_require_activation_code: false)

    assert {:error, :not_bound} =
             BullXAccounts.login_from_provider(channel_input("ou_provider_unmatched"))

    refute Repo.exists?(
             from user in User, where: user.display_name == "User ou_provider_unmatched"
           )

    refute Repo.exists?(
             from binding in UserChannelBinding,
               where: binding.external_id == "ou_provider_unmatched"
           )
  end

  test "bootstrap creates and logs a single activation code when no user or valid code exists" do
    Repo.delete_all(ActivationCode)

    log =
      capture_log(fn ->
        BullXAccounts.Bootstrap.run()
        BullXAccounts.Bootstrap.run()
      end)

    assert log =~ "BullX bootstrap activation code:"
    assert Repo.aggregate(ActivationCode, :count) == 1
  end

  defp put_accounts_config(opts \\ []) do
    defaults = [
      authn_match_rules: [],
      authn_auto_create_users: true,
      authn_require_activation_code: true,
      activation_code_ttl_seconds: 86_400,
      web_auth_code_ttl_seconds: 300
    ]

    Application.put_env(:bullx, :accounts, Keyword.merge(defaults, opts))
  end

  defp channel_input(external_id, opts \\ []) do
    profile =
      %{
        "display_name" => "User #{external_id}",
        "email" => "#{external_id}@unmatched.test"
      }
      |> Map.merge(Keyword.get(opts, :profile, %{}))

    %{
      adapter: :feishu,
      channel_id: "main",
      external_id: external_id,
      profile: profile,
      metadata: Keyword.get(opts, :metadata, %{})
    }
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
