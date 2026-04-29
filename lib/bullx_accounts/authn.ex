defmodule BullXAccounts.AuthN do
  @moduledoc """
  AuthN implementation for `BullXAccounts`.

  Owns identity creation, channel binding, activation codes, web auth codes,
  and session-user lookup. Public callers should go through the
  `BullXAccounts` facade; the docs here are the canonical reference for the
  delegated functions.

  Three flows interact here:

    * **Bootstrap activation code** — a single-use code minted at startup
      when no users exist; consuming it through `/preauth` assigns the
      created user to the built-in admin group. Created/refreshed under a
      Postgres advisory lock to prevent duplicates across racing boot
      attempts.
    * **Channel binding** — durable mapping from a Gateway actor
      `(adapter, channel_id, external_id)` to a `BullXAccounts.User`.
    * **Activation / login flows** — channel actors enter via one of three
      entry points (`resolve_channel_actor/3`, `match_or_create_from_channel/1`,
      `login_from_provider/1`) that differ in how they treat unbound actors.
  """

  import Ecto.Query

  alias BullX.Config.Accounts, as: AccountsConfig
  alias BullX.Repo
  alias BullXAccounts.ActivationCode
  alias BullXAccounts.AuthZ
  alias BullXAccounts.AuthZ.Cache
  alias BullXAccounts.Code
  alias BullXAccounts.User
  alias BullXAccounts.UserChannelAuthCode
  alias BullXAccounts.UserChannelBinding

  @bind_existing_user "bind_existing_user"
  @allow_create_user "allow_create_user"
  @user_fields %{"email" => :email, "phone" => :phone, "username" => :username}
  @bootstrap_metadata_key "bootstrap"
  @bootstrap_activation_code_lock_namespace 92_408
  @bootstrap_activation_code_lock_id 8

  @doc "Whether the system has zero users — the trigger for bootstrap activation."
  @spec setup_required?() :: boolean()
  def setup_required?, do: not Repo.exists?(from user in User, select: 1)

  @doc "Whether any bootstrap activation code has been consumed. Used to short-circuit further bootstrap minting after bootstrap preauth."
  @spec bootstrap_activation_code_consumed?() :: boolean()
  def bootstrap_activation_code_consumed? do
    Repo.exists?(
      from code in ActivationCode,
        where:
          not is_nil(code.used_at) and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        select: 1
    )
  end

  @doc """
  Whether an unused, unrevoked, unexpired bootstrap code exists.

  Distinct from `bootstrap_activation_code_consumed?/0`: a fresh DB has
  `pending? = true` and `consumed? = false`; after bootstrap preauth
  consumes the code, both flip.
  """
  @spec bootstrap_activation_code_pending?() :: boolean()
  def bootstrap_activation_code_pending? do
    now = utc_now()

    Repo.exists?(
      from code in ActivationCode,
        where:
          is_nil(code.used_at) and is_nil(code.revoked_at) and code.expires_at > ^now and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        select: 1
    )
  end

  @doc """
  Verify a plaintext bootstrap code and return its hash.

  The hash is returned (rather than just `:ok`) so a later step can re-check
  validity via `bootstrap_activation_code_valid_for_hash?/1` without
  repeating the argon2 cost.
  """
  @spec verify_bootstrap_activation_code(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_or_expired_code}
  def verify_bootstrap_activation_code(plaintext) when is_binary(plaintext) do
    now = utc_now()

    candidates =
      Repo.all(
        from code in ActivationCode,
          where:
            is_nil(code.used_at) and is_nil(code.revoked_at) and code.expires_at > ^now and
              fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
          order_by: [asc: code.inserted_at],
          select: code.code_hash
      )

    case Enum.find(candidates, &Code.verified?(plaintext, &1)) do
      nil -> {:error, :invalid_or_expired_code}
      hash -> {:ok, hash}
    end
  end

  @doc "Whether the given `code_hash` still names a usable bootstrap code. Pair with `verify_bootstrap_activation_code/1` to verify once and consume later."
  @spec bootstrap_activation_code_valid_for_hash?(String.t() | nil) :: boolean()
  def bootstrap_activation_code_valid_for_hash?(code_hash) when is_binary(code_hash) do
    now = utc_now()

    Repo.exists?(
      from code in ActivationCode,
        where:
          code.code_hash == ^code_hash and is_nil(code.used_at) and is_nil(code.revoked_at) and
            code.expires_at > ^now and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        select: 1
    )
  end

  def bootstrap_activation_code_valid_for_hash?(_code_hash), do: false

  @doc """
  Mint or rotate the bootstrap activation code under a Postgres advisory lock.

  The lock prevents concurrent boot attempts (e.g. simultaneous releases)
  from producing duplicate bootstrap codes. Returns `:created` for a fresh
  code, `:refreshed` when an existing unused code's secret was rotated.
  Errors with `:bootstrap_not_required` (users exist) or
  `:bootstrap_already_consumed`.
  """
  @spec create_or_refresh_bootstrap_activation_code() ::
          {:ok,
           %{code: String.t(), activation_code: ActivationCode.t(), action: :created | :refreshed}}
          | {:error, term()}
  def create_or_refresh_bootstrap_activation_code do
    transaction(fn ->
      :ok = lock_bootstrap_activation_code!()

      cond do
        not setup_required?() -> {:error, :bootstrap_not_required}
        bootstrap_activation_code_consumed?() -> {:error, :bootstrap_already_consumed}
        true -> create_or_refresh_bootstrap_activation_code_in_transaction()
      end
    end)
  end

  @doc """
  Read-only lookup from a Gateway channel actor to a user.

  Errors with `:not_bound` when the actor has no binding — does **not**
  auto-create. Use `match_or_create_from_channel/1` or
  `login_from_provider/1` when binding-on-first-contact is desired.
  """
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

  @doc """
  Resolve a session's stored `user_id` (typically from a signed cookie) to
  an active user.

  Banned users are rejected with `:user_banned` rather than `:not_found` so
  the session layer can clear the session deliberately rather than treating
  it as a stale id.
  """
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

  @doc """
  Toggle a user's `status` between `:active` and `:banned`.

  Invalidates the entire AuthZ decision/group cache on success — banning a
  user takes effect on the next authorize call rather than waiting for cache
  TTL expiry.
  """
  @spec update_user_status(User.t() | Ecto.UUID.t(), :active | :banned) ::
          {:ok, User.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def update_user_status(%User{} = user, status) when status in [:active, :banned] do
    user
    |> Ecto.Changeset.change(%{status: status})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cache.invalidate_all()
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_user_status(id, status) when is_binary(id) and status in [:active, :banned] do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(User, uuid) do
          nil -> {:error, :not_found}
          user -> update_user_status(user, status)
        end

      :error ->
        {:error, :not_found}
    end
  end

  def update_user_status(_user, _status), do: {:error, :not_found}

  @doc """
  Bind, look up, or auto-create a user from a Gateway channel actor.

  Dispatch is rule-driven (`accounts.authn.match_rules`):

    1. Already-bound actor → returns the existing user.
    2. `bind_existing_user` rule matches → bind the channel to that user.
    3. `allow_create_user` rule matches **and** `auto_create_users` is on
       → create a new user.
    4. Otherwise → `:activation_required`, so the caller can prompt for an
       activation code (then `consume_activation_code/2`).

  Banned matched users always error with `:user_banned`; matching never
  re-binds to them.
  """
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

  @doc """
  Authenticate a returning user via an OAuth/OIDC-style provider channel.

  Differs from `match_or_create_from_channel/1` in that an unmatched, unbound
  actor errors with `:not_bound` rather than `:activation_required` —
  provider flows assume the upstream IdP is the source of truth and there
  is no "send me an activation code" affordance.
  """
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

  @doc """
  Mint a new activation code and persist its argon2 hash.

  The plaintext code is returned in the result so the caller can deliver it
  once; it is unrecoverable from the database afterwards. `metadata` is
  caller-defined provenance (e.g. inviter, channel of issuance) and is
  preserved into the `consumed` block when the code is later used.
  """
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

  @doc """
  Revoke an unused activation code.

  Already-used, already-revoked, and expired codes are not distinguished
  from genuinely missing ids — all return `{:error, :not_found}`. Callers
  needing finer reasons should query the row before revoking.
  """
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

  @doc """
  Trade an activation code for a `(user, channel_binding)` pair.

  Three-step in-transaction logic:

    1. If the channel actor is already bound, fail with `:already_bound`.
       The code is **not** consumed.
    2. Otherwise, run the standard match rules first — if they bind or
       auto-create successfully, the code is left untouched.
    3. Only when no rule applies do we verify the plaintext code, mark it
       used, and create the user + binding.

  A holder of a valid activation code may end up bound to an existing user
  (step 2) without "spending" the code.
  """
  @spec consume_activation_code(String.t(), map()) ::
          {:ok, User.t(), UserChannelBinding.t()}
          | {:error, :invalid_or_expired_code}
          | {:error, :already_bound}
          | {:error, term()}
  def consume_activation_code(plaintext_code, input)
      when is_binary(plaintext_code) and is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn -> consume_activation_code_in_transaction(plaintext_code, normalized) end)
    end
  end

  @doc """
  Issue a one-time web auth code for an already-bound channel actor.

  The plaintext is returned once and meant to be relayed back to the user
  through their channel (e.g. a chat DM). The web client redeems it via
  `consume_user_channel_auth_code/1`. Codes are short-lived (configurable
  TTL) and consumed exactly once.
  """
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

  @doc """
  Redeem a web auth code (from `issue_user_channel_auth_code/3`) for its user.

  The code row is deleted on success — codes are strictly single-use.
  Banned users fail with `:user_banned` even given a valid code.
  """
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
    case fetch_binding_state(input) do
      :not_found -> consume_activation_code_for_unbound_actor(plaintext_code, input)
      {:ok, _user, _binding} -> {:error, :already_bound}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_activation_code_for_unbound_actor(plaintext_code, input) do
    case automatic_match_result(input) do
      {:ok, _user, _binding} = result ->
        result

      :none ->
        with {:ok, activation_code} <- find_valid_activation_code(plaintext_code),
             :ok <- mark_activation_code_used(activation_code, input),
             {:ok, user, binding} <- create_user_and_binding(input),
             :ok <- maybe_grant_bootstrap_admin(activation_code, user) do
          {:ok, user, binding}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp automatic_match_result(input) do
    case evaluate_match_rules(input) do
      {:bind, user} ->
        bind_user_to_channel(user, input)

      :allow_create ->
        activation_required_to_none(auto_create_if_enabled(input))

      :no_match ->
        activation_required_to_none(auto_create_unmatched(input))

      {:error, :user_banned} ->
        {:error, :user_banned}
    end
  end

  defp activation_required_to_none({:error, :activation_required}), do: :none
  defp activation_required_to_none(result), do: result

  defp maybe_grant_bootstrap_admin(%ActivationCode{} = activation_code, %User{} = user) do
    case bootstrap_activation_code?(activation_code) do
      true -> AuthZ.grant_bootstrap_admin(user)
      false -> :ok
    end
  end

  defp bootstrap_activation_code?(%ActivationCode{metadata: metadata}) do
    metadata = normalize_metadata(metadata)
    metadata[@bootstrap_metadata_key] == true
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
    case insert_user(input) do
      {:ok, user} -> insert_first_binding(user, input)
      {:error, changeset} -> existing_binding_or_error(changeset, input)
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
      {:error, changeset} -> existing_binding_after_conflict(changeset, input)
    end
  end

  defp insert_first_binding(%User{} = created_user, input) do
    case insert_binding(created_user, input) do
      {:ok, %User{id: id}, _binding} = result when id == created_user.id ->
        result

      {:ok, _existing_user, _binding} = result ->
        Repo.delete!(created_user)
        result

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp existing_binding_after_conflict(changeset, input) do
    case binding_unique_conflict?(changeset) do
      true -> existing_binding_or_error(changeset, input)
      false -> {:error, changeset}
    end
  end

  defp existing_binding_or_error(changeset, input) do
    case fetch_binding_state(input) do
      {:ok, user, binding} -> {:ok, user, binding}
      _other -> {:error, changeset}
    end
  end

  defp binding_unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          to_string(Keyword.get(opts, :constraint_name)) == "user_channel_bindings_actor_index"
    end)
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

  defp fetch_unused_bootstrap_activation_code do
    Repo.one(
      from code in ActivationCode,
        where:
          is_nil(code.used_at) and is_nil(code.revoked_at) and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        order_by: [asc: code.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp lock_bootstrap_activation_code! do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock($1::integer, $2::integer)",
      [@bootstrap_activation_code_lock_namespace, @bootstrap_activation_code_lock_id]
    )

    :ok
  end

  defp create_or_refresh_bootstrap_activation_code_in_transaction do
    case fetch_unused_bootstrap_activation_code() do
      nil -> create_bootstrap_activation_code()
      %ActivationCode{} = existing -> refresh_bootstrap_activation_code(existing)
    end
  end

  defp create_bootstrap_activation_code do
    plaintext = Code.activation_code()

    with {:ok, code_hash} <- Code.hash(plaintext) do
      attrs = %{
        code_hash: code_hash,
        expires_at: expires_at(AccountsConfig.accounts_activation_code_ttl_seconds!()),
        created_by_user_id: nil,
        metadata: %{@bootstrap_metadata_key => true}
      }

      %ActivationCode{}
      |> ActivationCode.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, activation_code} ->
          {:ok, %{code: plaintext, activation_code: activation_code, action: :created}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp refresh_bootstrap_activation_code(%ActivationCode{} = existing) do
    plaintext = Code.activation_code()
    now = utc_now()

    with {:ok, code_hash} <- Code.hash(plaintext) do
      attrs = %{
        code_hash: code_hash,
        expires_at: expires_at(AccountsConfig.accounts_activation_code_ttl_seconds!()),
        metadata: refreshed_bootstrap_metadata(existing.metadata, now)
      }

      existing
      |> ActivationCode.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, activation_code} ->
          {:ok, %{code: plaintext, activation_code: activation_code, action: :refreshed}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp refreshed_bootstrap_metadata(metadata, now) do
    metadata
    |> normalize_metadata()
    |> Map.put(@bootstrap_metadata_key, true)
    |> Map.put("refreshed_at", DateTime.to_iso8601(now))
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

  defp normalize_identifier(value) when value in [nil, true, false],
    do: {:error, :invalid_identifier}

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
