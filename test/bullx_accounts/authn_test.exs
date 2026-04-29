defmodule BullXAccounts.AuthNTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User
  alias BullXAccounts.UserChannelAuthCode
  alias BullXAccounts.UserChannelBinding
  alias BullXAccounts.UserGroup
  alias BullXAccounts.UserGroupMembership

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
    refute admin_member?(user)

    assert {:error, :already_bound} = BullXAccounts.consume_activation_code(code, input)
  end

  test "bootstrap activation code consumption grants admin membership to the preauth user" do
    Repo.delete_all(ActivationCode)

    assert {:ok, %{code: code, activation_code: activation_code}} =
             BullXAccounts.create_or_refresh_bootstrap_activation_code()

    assert activation_code.metadata == %{"bootstrap" => true}

    assert {:ok, user, binding} =
             BullXAccounts.consume_activation_code(code, channel_input("ou_bootstrap_admin"))

    assert binding.user_id == user.id
    assert admin_member?(user)

    used_code = Repo.get!(ActivationCode, activation_code.id)
    assert used_code.used_at
    assert used_code.metadata["bootstrap"] == true
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

  test "bootstrap activation code does not grant admin when automatic matching avoids consumption" do
    Repo.delete_all(ActivationCode)

    assert {:ok, %{code: code, activation_code: activation_code}} =
             BullXAccounts.create_or_refresh_bootstrap_activation_code()

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
             BullXAccounts.consume_activation_code(
               code,
               channel_input("ou_bootstrap_match", profile: %{"email" => user.email})
             )

    assert resolved.id == user.id
    assert binding.user_id == user.id
    assert Repo.get!(ActivationCode, activation_code.id).used_at == nil
    refute admin_member?(user)
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

  test "bootstrap creates one bootstrap activation code on first run and refreshes it on the second" do
    Repo.delete_all(ActivationCode)

    log_first =
      capture_log(fn ->
        BullXAccounts.Bootstrap.run()
      end)

    [created] = Repo.all(ActivationCode)
    assert created.metadata == %{"bootstrap" => true}
    assert is_nil(created.used_at)
    assert log_first =~ "BullX bootstrap activation code (created):"

    log_second =
      capture_log(fn ->
        BullXAccounts.Bootstrap.run()
      end)

    [refreshed] = Repo.all(ActivationCode)
    assert refreshed.id == created.id
    assert refreshed.code_hash != created.code_hash
    assert DateTime.compare(refreshed.expires_at, created.expires_at) in [:gt, :eq]
    assert refreshed.metadata["bootstrap"] == true
    assert is_binary(refreshed.metadata["refreshed_at"])
    assert log_second =~ "BullX bootstrap activation code (refreshed):"
  end

  test "concurrent bootstrap create_or_refresh keeps a single bootstrap row" do
    Repo.delete_all(ActivationCode)

    test_pid = self()

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
          BullXAccounts.create_or_refresh_bootstrap_activation_code()
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, %{action: :created}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{action: :refreshed}}, &1)) == 4

    [row] = Repo.all(ActivationCode)
    assert row.metadata["bootstrap"] == true
    assert is_nil(row.used_at)
  end

  test "bootstrap does nothing when a bootstrap activation code has already been consumed" do
    Repo.delete_all(ActivationCode)

    consumed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %ActivationCode{}
    |> ActivationCode.changeset(%{
      code_hash: "argon2id$consumed-bootstrap",
      expires_at: DateTime.add(consumed_at, 86_400, :second),
      used_at: consumed_at,
      used_by_adapter: "feishu",
      used_by_channel_id: "main",
      used_by_external_id: "ou_consumer",
      metadata: %{"bootstrap" => true}
    })
    |> Repo.insert!()

    log = capture_log(fn -> BullXAccounts.Bootstrap.run() end)

    refute log =~ "BullX bootstrap activation code"
    assert Repo.aggregate(ActivationCode, :count) == 1
  end

  test "bootstrap does nothing when any user already exists" do
    Repo.delete_all(ActivationCode)
    insert_user!(display_name: "Existing")

    log = capture_log(fn -> BullXAccounts.Bootstrap.run() end)

    refute log =~ "BullX bootstrap activation code"
    assert Repo.aggregate(ActivationCode, :count) == 0
  end

  test "bootstrap_activation_code_pending? matches the lifecycle of the bootstrap row" do
    Repo.delete_all(ActivationCode)
    refute BullXAccounts.bootstrap_activation_code_pending?()

    {:ok, %{activation_code: row}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    assert BullXAccounts.bootstrap_activation_code_pending?()

    {:ok, _} = BullXAccounts.revoke_activation_code(row)
    refute BullXAccounts.bootstrap_activation_code_pending?()

    Repo.delete_all(ActivationCode)
    refute BullXAccounts.bootstrap_activation_code_pending?()

    {:ok, _} = BullXAccounts.create_activation_code(nil, %{source: "operator"})
    refute BullXAccounts.bootstrap_activation_code_pending?()
  end

  test "verify_bootstrap_activation_code returns the matched row's hash on a valid plaintext" do
    Repo.delete_all(ActivationCode)

    {:ok, %{code: plaintext, activation_code: row}} =
      BullXAccounts.create_or_refresh_bootstrap_activation_code()

    assert {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)
    assert code_hash == row.code_hash
  end

  test "verify_bootstrap_activation_code rejects unknown, revoked, used, expired, or operator codes" do
    Repo.delete_all(ActivationCode)

    {:ok, %{code: plaintext_a, activation_code: row_a}} =
      BullXAccounts.create_or_refresh_bootstrap_activation_code()

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.verify_bootstrap_activation_code("NOT-THE-CODE")

    {:ok, _} = BullXAccounts.revoke_activation_code(row_a)

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.verify_bootstrap_activation_code(plaintext_a)

    Repo.delete_all(ActivationCode)

    {:ok, %{code: plaintext_b, activation_code: row_b}} =
      BullXAccounts.create_or_refresh_bootstrap_activation_code()

    row_b
    |> Ecto.Changeset.change(%{
      used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      used_by_adapter: "feishu",
      used_by_channel_id: "main",
      used_by_external_id: "ou_marker"
    })
    |> Repo.update!()

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.verify_bootstrap_activation_code(plaintext_b)

    Repo.delete_all(ActivationCode)

    {:ok, %{code: plaintext_c, activation_code: row_c}} =
      BullXAccounts.create_or_refresh_bootstrap_activation_code()

    row_c
    |> Ecto.Changeset.change(%{
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update!()

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.verify_bootstrap_activation_code(plaintext_c)

    Repo.delete_all(ActivationCode)

    {:ok, %{code: operator_plaintext}} =
      BullXAccounts.create_activation_code(nil, %{source: "operator"})

    assert {:error, :invalid_or_expired_code} =
             BullXAccounts.verify_bootstrap_activation_code(operator_plaintext)
  end

  test "bootstrap_activation_code_valid_for_hash? matches only the live bootstrap row" do
    Repo.delete_all(ActivationCode)

    refute BullXAccounts.bootstrap_activation_code_valid_for_hash?(nil)
    refute BullXAccounts.bootstrap_activation_code_valid_for_hash?("does-not-exist")

    {:ok, %{code: plaintext, activation_code: row}} =
      BullXAccounts.create_or_refresh_bootstrap_activation_code()

    assert {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)
    assert BullXAccounts.bootstrap_activation_code_valid_for_hash?(code_hash)

    {:ok, _} = BullXAccounts.revoke_activation_code(row)
    refute BullXAccounts.bootstrap_activation_code_valid_for_hash?(code_hash)

    Repo.delete_all(ActivationCode)

    {:ok, %{activation_code: operator_row}} =
      BullXAccounts.create_activation_code(nil, %{source: "operator"})

    refute BullXAccounts.bootstrap_activation_code_valid_for_hash?(operator_row.code_hash)
  end

  test "bootstrap ignores operator-issued activation codes when deciding whether to issue a bootstrap code" do
    Repo.delete_all(ActivationCode)

    {:ok, %{activation_code: operator_code}} =
      BullXAccounts.create_activation_code(nil, %{source: "operator"})

    log = capture_log(fn -> BullXAccounts.Bootstrap.run() end)

    bootstrap_codes =
      ActivationCode
      |> Repo.all()
      |> Enum.filter(&(&1.metadata["bootstrap"] == true))

    assert log =~ "BullX bootstrap activation code (created):"
    assert length(bootstrap_codes) == 1
    assert Repo.get!(ActivationCode, operator_code.id).metadata["bootstrap"] != true
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

  defp admin_member?(%User{id: user_id}) do
    case Repo.get_by(UserGroup, name: "admin") do
      nil ->
        false

      %UserGroup{id: group_id} ->
        Repo.exists?(
          from membership in UserGroupMembership,
            where: membership.user_id == ^user_id and membership.group_id == ^group_id
        )
    end
  end
end
