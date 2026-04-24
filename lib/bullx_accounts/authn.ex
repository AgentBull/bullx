defmodule BullXAccounts.AuthN do
  @moduledoc false

  import Ecto.Query

  alias BullX.Config.Accounts, as: AccountsConfig
  alias BullX.Repo
  alias BullXAccounts.ActivationCode
  alias BullXAccounts.Code
  alias BullXAccounts.User
  alias BullXAccounts.UserChannelAuthCode
  alias BullXAccounts.UserChannelBinding

  @bind_existing_user "bind_existing_user"
  @allow_create_user "allow_create_user"
  @user_fields %{"email" => :email, "phone" => :phone, "username" => :username}

  @spec setup_required?() :: boolean()
  def setup_required?, do: not Repo.exists?(from user in User, select: 1)

  @spec resolve_channel_actor(atom() | String.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :not_bound} | {:error, :user_banned}
  def resolve_channel_actor(adapter, channel_id, external_id) do
    with {:ok, input} <- normalize_channel_ref(adapter, channel_id, external_id) do
      case fetch_binding_state(input) do
        {:ok, user, _binding} -> {:ok, user}
        :not_found -> {:error, :not_bound}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec fetch_session_user(String.t() | nil) ::
          {:ok, User.t()} | {:error, :not_found} | {:error, :user_banned}
  def fetch_session_user(nil), do: {:error, :not_found}

  def fetch_session_user(user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> fetch_session_user_by_id(id)
      :error -> {:error, :not_found}
    end
  end

  def fetch_session_user(_user_id), do: {:error, :not_found}

  @spec match_or_create_from_channel(map()) ::
          {:ok, User.t(), UserChannelBinding.t()}
          | {:error, :activation_required}
          | {:error, :user_banned}
          | {:error, term()}
  def match_or_create_from_channel(input) when is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn ->
        case fetch_binding_state(normalized) do
          {:ok, user, binding} -> {:ok, user, binding}
          {:error, reason} -> {:error, reason}
          :not_found -> match_unbound_channel(normalized)
        end
      end)
    end
  end

  @spec login_from_provider(map()) ::
          {:ok, User.t(), UserChannelBinding.t()}
          | {:error, :not_bound}
          | {:error, :user_banned}
          | {:error, term()}
  def login_from_provider(input) when is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn ->
        case fetch_binding_state(normalized) do
          {:ok, user, binding} -> {:ok, user, binding}
          {:error, reason} -> {:error, reason}
          :not_found -> match_provider_channel(normalized)
        end
      end)
    end
  end

  @spec create_activation_code(User.t() | nil, map()) ::
          {:ok, %{code: String.t(), activation_code: ActivationCode.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def create_activation_code(created_by_user, metadata \\ %{}) do
    code = Code.activation_code()

    with {:ok, code_hash} <- Code.hash(code) do
      attrs = %{
        code_hash: code_hash,
        expires_at: expires_at(AccountsConfig.accounts_activation_code_ttl_seconds!()),
        created_by_user_id: created_by_user_id(created_by_user),
        metadata: normalize_metadata(metadata)
      }

      %ActivationCode{}
      |> ActivationCode.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, activation_code} -> {:ok, %{code: code, activation_code: activation_code}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @spec revoke_activation_code(ActivationCode.t() | String.t()) ::
          {:ok, ActivationCode.t()} | {:error, :not_found}
  def revoke_activation_code(%ActivationCode{id: id}), do: revoke_activation_code(id)

  def revoke_activation_code(id) when is_binary(id) do
    now = utc_now()

    {count, _} =
      Repo.update_all(
        from(code in ActivationCode,
          where:
            code.id == ^id and is_nil(code.revoked_at) and is_nil(code.used_at) and
              code.expires_at > ^now
        ),
        set: [revoked_at: now, updated_at: now]
      )

    case count do
      1 -> {:ok, Repo.get!(ActivationCode, id)}
      0 -> {:error, :not_found}
    end
  end

  @spec consume_activation_code(String.t(), map()) ::
          {:ok, User.t(), UserChannelBinding.t()}
          | {:error, :invalid_or_expired_code}
          | {:error, :already_bound}
          | {:error, :auto_match_available}
          | {:error, term()}
  def consume_activation_code(plaintext_code, input)
      when is_binary(plaintext_code) and is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn -> consume_activation_code_in_transaction(plaintext_code, normalized) end)
    end
  end

  @spec issue_user_channel_auth_code(atom() | String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_bound} | {:error, :user_banned} | {:error, term()}
  def issue_user_channel_auth_code(adapter, channel_id, external_id) do
    with {:ok, user} <- resolve_channel_actor(adapter, channel_id, external_id),
         code <- Code.web_auth_code(),
         {:ok, code_hash} <- Code.hash(code),
         {:ok, _auth_code} <-
           %UserChannelAuthCode{}
           |> UserChannelAuthCode.changeset(%{code_hash: code_hash, user_id: user.id})
           |> Repo.insert() do
      {:ok, code}
    end
  end

  @spec consume_user_channel_auth_code(String.t()) ::
          {:ok, User.t()} | {:error, :invalid_or_expired_code} | {:error, :user_banned}
  def consume_user_channel_auth_code(plaintext_code) when is_binary(plaintext_code) do
    transaction(fn ->
      plaintext_code
      |> find_valid_user_channel_auth_code()
      |> consume_verified_user_channel_auth_code()
    end)
  end

  defp fetch_session_user_by_id(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      %User{status: :active} = user -> {:ok, user}
      %User{status: :banned} -> {:error, :user_banned}
    end
  end

  defp match_unbound_channel(input) do
    case evaluate_match_rules(input) do
      {:bind, user} -> bind_user_to_channel(user, input)
      :allow_create -> auto_create_if_enabled(input)
      :no_match -> auto_create_unmatched(input)
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_provider_channel(input) do
    case evaluate_match_rules(input) do
      {:bind, user} -> bind_user_to_channel(user, input)
      :allow_create -> create_provider_user_if_enabled(input)
      :no_match -> {:error, :not_bound}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_provider_user_if_enabled(input) do
    case AccountsConfig.accounts_authn_auto_create_users!() do
      true -> create_user_and_binding(input)
      false -> {:error, :not_bound}
    end
  end

  defp auto_create_if_enabled(input) do
    case AccountsConfig.accounts_authn_auto_create_users!() do
      true -> create_user_and_binding(input)
      false -> {:error, :activation_required}
    end
  end

  defp auto_create_unmatched(input) do
    case {AccountsConfig.accounts_authn_auto_create_users!(),
          AccountsConfig.accounts_authn_require_activation_code!()} do
      {true, false} -> create_user_and_binding(input)
      _ -> {:error, :activation_required}
    end
  end

  defp consume_activation_code_in_transaction(plaintext_code, input) do
    with :not_found <- fetch_binding_state(input),
         :none <- automatic_match_state(input),
         {:ok, activation_code} <- find_valid_activation_code(plaintext_code),
         :ok <- mark_activation_code_used(activation_code, input) do
      create_user_and_binding(input)
    else
      {:ok, _user, _binding} -> {:error, :already_bound}
      {:error, reason} -> {:error, reason}
      :available -> {:error, :auto_match_available}
    end
  end

  defp automatic_match_state(input) do
    case evaluate_match_rules(input) do
      {:bind, _user} ->
        :available

      :allow_create ->
        if AccountsConfig.accounts_authn_auto_create_users!(), do: :available, else: :none

      :no_match ->
        case {AccountsConfig.accounts_authn_auto_create_users!(),
              AccountsConfig.accounts_authn_require_activation_code!()} do
          {true, false} -> :available
          _ -> :none
        end

      {:error, :user_banned} ->
        {:error, :user_banned}
    end
  end

  defp evaluate_match_rules(input) do
    AccountsConfig.accounts_authn_match_rules!()
    |> Enum.reduce_while(:no_match, fn rule, :no_match ->
      case evaluate_rule(rule, input) do
        :no_match -> {:cont, :no_match}
        result -> {:halt, result}
      end
    end)
  end

  defp evaluate_rule(%{"result" => @bind_existing_user} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, field} <- fetch_user_field(rule["user_field"]),
         {:ok, normalized_value} <- normalize_lookup_value(rule["user_field"], value) do
      case fetch_user_by_field(field, normalized_value) do
        nil -> :no_match
        %User{status: :active} = user -> {:bind, user}
        %User{status: :banned} -> {:error, :user_banned}
      end
    else
      _ -> :no_match
    end
  end

  defp evaluate_rule(%{"result" => @allow_create_user, "op" => "email_domain_in"} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, email} <- normalize_lookup_value("email", value),
         [_local, domain] <- String.split(email, "@", parts: 2),
         true <- domain in rule["domains"] do
      :allow_create
    else
      _ -> :no_match
    end
  end

  defp evaluate_rule(%{"result" => @allow_create_user, "op" => "equals_any"} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, normalized_value} <- normalize_lookup_value(nil, value),
         true <- normalized_value in rule["values"] do
      :allow_create
    else
      _ -> :no_match
    end
  end

  defp fetch_binding_state(input) do
    case fetch_binding(input.adapter, input.channel_id, input.external_id) do
      nil -> :not_found
      %UserChannelBinding{user: %User{status: :active} = user} = binding -> {:ok, user, binding}
      %UserChannelBinding{user: %User{status: :banned}} -> {:error, :user_banned}
    end
  end

  defp fetch_binding(adapter, channel_id, external_id) do
    Repo.one(
      from binding in UserChannelBinding,
        where:
          binding.adapter == ^adapter and binding.channel_id == ^channel_id and
            binding.external_id == ^external_id,
        preload: [:user]
    )
  end

  defp fetch_user_by_field(field, value) do
    Repo.one(from user in User, where: field(user, ^field) == ^value)
  end

  defp bind_user_to_channel(%User{status: :active} = user, input) do
    insert_binding(user, input)
  end

  defp bind_user_to_channel(%User{status: :banned}, _input), do: {:error, :user_banned}

  defp create_user_and_binding(input) do
    with {:ok, user} <- insert_user(input),
         {:ok, _user, binding} <- insert_binding(user, input) do
      {:ok, user, binding}
    end
  end

  defp insert_user(input) do
    %User{}
    |> User.changeset(user_attrs(input))
    |> Repo.insert()
  end

  defp insert_binding(user, input) do
    attrs = %{
      user_id: user.id,
      adapter: input.adapter,
      channel_id: input.channel_id,
      external_id: input.external_id,
      metadata: binding_metadata(input)
    }

    %UserChannelBinding{}
    |> UserChannelBinding.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, binding} -> {:ok, user, binding}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp user_attrs(input) do
    profile = input.profile

    %{
      username: profile["username"],
      email: profile["email"],
      phone: profile["phone"],
      display_name: display_name(input),
      avatar_url: profile["avatar_url"],
      status: :active
    }
  end

  defp display_name(input) do
    input.profile["display_name"] || input.profile["display"] || input.external_id
  end

  defp binding_metadata(input) do
    %{
      "profile" => input.profile,
      "metadata" => input.metadata
    }
  end

  defp find_valid_activation_code(plaintext_code) do
    now = utc_now()

    ActivationCode
    |> valid_activation_codes_query(now)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.find(&Code.verified?(plaintext_code, &1.code_hash))
    |> case do
      nil -> {:error, :invalid_or_expired_code}
      activation_code -> {:ok, activation_code}
    end
  end

  defp valid_activation_codes_query(query, now) do
    from code in query,
      where: is_nil(code.revoked_at) and is_nil(code.used_at) and code.expires_at > ^now,
      order_by: [asc: code.inserted_at]
  end

  defp mark_activation_code_used(%ActivationCode{} = activation_code, input) do
    now = utc_now()
    metadata = activation_code_metadata(activation_code.metadata, input, now)

    {count, _} =
      Repo.update_all(
        from(code in ActivationCode,
          where:
            code.id == ^activation_code.id and is_nil(code.revoked_at) and is_nil(code.used_at) and
              code.expires_at > ^now
        ),
        set: [
          used_at: now,
          used_by_adapter: input.adapter,
          used_by_channel_id: input.channel_id,
          used_by_external_id: input.external_id,
          metadata: metadata,
          updated_at: now
        ]
      )

    case count do
      1 -> :ok
      0 -> {:error, :invalid_or_expired_code}
    end
  end

  defp activation_code_metadata(metadata, input, now) do
    metadata = normalize_metadata(metadata)

    Map.put(metadata, "consumed", %{
      "adapter" => input.adapter,
      "channel_id" => input.channel_id,
      "external_id" => input.external_id,
      "at" => DateTime.to_iso8601(now)
    })
  end

  defp find_valid_user_channel_auth_code(plaintext_code) do
    threshold =
      AccountsConfig.accounts_web_auth_code_ttl_seconds!()
      |> then(&DateTime.add(utc_now(), -&1, :second))

    UserChannelAuthCode
    |> where([code], code.inserted_at > ^threshold)
    |> order_by([code], asc: code.inserted_at)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.find(&Code.verified?(plaintext_code, &1.code_hash))
    |> case do
      nil -> {:error, :invalid_or_expired_code}
      auth_code -> {:ok, auth_code}
    end
  end

  defp consume_verified_user_channel_auth_code({:error, reason}), do: {:error, reason}

  defp consume_verified_user_channel_auth_code({:ok, auth_code}) do
    auth_code = Repo.preload(auth_code, :user)

    case auth_code.user do
      %User{status: :active} = user ->
        with {:ok, _deleted} <- Repo.delete(auth_code) do
          {:ok, user}
        end

      %User{status: :banned} ->
        {:error, :user_banned}
    end
  end

  defp normalize_channel_ref(adapter, channel_id, external_id) do
    with {:ok, adapter} <- normalize_identifier(adapter),
         {:ok, channel_id} <- normalize_identifier(channel_id),
         {:ok, external_id} <- normalize_identifier(external_id) do
      {:ok, %{adapter: adapter, channel_id: channel_id, external_id: external_id}}
    end
  end

  defp normalize_channel_input(input) do
    with {:ok, input} <- stringify_map(input),
         {:ok, adapter} <- fetch_identifier(input, "adapter"),
         {:ok, channel_id} <- fetch_identifier(input, "channel_id"),
         {:ok, external_id} <- fetch_identifier(input, "external_id"),
         {:ok, profile} <- optional_map(input, "profile"),
         {:ok, metadata} <- optional_map(input, "metadata") do
      {:ok,
       %{
         adapter: adapter,
         channel_id: channel_id,
         external_id: external_id,
         profile: normalize_identity_map(profile),
         metadata: metadata
       }}
    end
  end

  defp optional_map(map, key) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> {:ok, value}
      _value -> {:error, {:invalid_channel_input, key}}
    end
  end

  defp fetch_identifier(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> normalize_identifier(value)
      :error -> {:error, {:missing_channel_input, key}}
    end
  end

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> {:error, :blank_identifier}
      value -> {:ok, value}
    end
  end

  defp normalize_identifier(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_identifier(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp normalize_identifier(_value), do: {:error, :invalid_identifier}

  defp normalize_identity_map(map) do
    map
    |> normalize_identity_field("email", &String.downcase/1)
    |> normalize_identity_field("phone", &Function.identity/1)
    |> normalize_identity_field("username", &Function.identity/1)
    |> normalize_identity_field("display_name", &Function.identity/1)
    |> normalize_identity_field("display", &Function.identity/1)
    |> normalize_identity_field("avatar_url", &Function.identity/1)
  end

  defp normalize_identity_field(map, field, fun) do
    case Map.fetch(map, field) do
      {:ok, value} ->
        case normalize_lookup_value(field, value) do
          {:ok, normalized} -> Map.put(map, field, fun.(normalized))
          :error -> Map.delete(map, field)
        end

      :error ->
        map
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    case stringify_map(metadata) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> %{}
    end
  end

  defp normalize_metadata(_metadata), do: %{}

  defp stringify_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- stringify_key(key),
           {:ok, value} <- stringify_value(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stringify_map(_map), do: {:error, :invalid_map}

  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(_key), do: {:error, :invalid_map_key}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value), do: {:ok, value}

  defp get_source_value(input, source_path) do
    source_path
    |> String.split(".")
    |> Enum.reduce_while(%{"profile" => input.profile, "metadata" => input.metadata}, fn key,
                                                                                         current ->
      case current do
        %{^key => value} -> {:cont, value}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      value -> present_source_value(value)
    end
  end

  defp present_source_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> :error
      value -> {:ok, value}
    end
  end

  defp present_source_value(nil), do: :error
  defp present_source_value(value), do: {:ok, value}

  defp fetch_user_field(field) do
    case Map.fetch(@user_fields, field) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp normalize_lookup_value("email", value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> non_blank_string()
  end

  defp normalize_lookup_value("phone", value) when is_binary(value) do
    value
    |> String.trim()
    |> non_blank_string()
    |> normalize_phone_lookup()
  end

  defp normalize_lookup_value(_field, value) when is_binary(value) do
    value
    |> String.trim()
    |> non_blank_string()
  end

  defp normalize_lookup_value(_field, value) when is_integer(value),
    do: {:ok, Integer.to_string(value)}

  defp normalize_lookup_value(_field, value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_lookup_value(_field, _value), do: :error

  defp normalize_phone_lookup({:ok, phone}) do
    case BullX.Ext.phone_normalize_e164(phone) do
      e164 when is_binary(e164) -> {:ok, e164}
      {:error, _reason} -> :error
    end
  end

  defp normalize_phone_lookup(:error), do: :error

  defp non_blank_string(""), do: :error
  defp non_blank_string(value), do: {:ok, value}

  defp created_by_user_id(nil), do: nil
  defp created_by_user_id(%User{id: id}), do: id

  defp expires_at(ttl_seconds), do: DateTime.add(utc_now(), ttl_seconds, :second)

  defp utc_now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end

  defp transaction(fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             other -> other
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
