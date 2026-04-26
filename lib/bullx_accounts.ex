defmodule BullXAccounts do
  @moduledoc """
  AuthN and AuthZ boundary for durable BullX users.

  AuthN owns identity, login, channel binding, activation, and sessions.
  AuthZ consumes durable users as principals and decides whether an active
  user may perform an action on a resource. Gateway actors remain
  channel-local; callers resolve a BullX identity through this facade only
  when business identity is required.
  """

  alias BullXAccounts.AuthN
  alias BullXAccounts.AuthZ

  ## AuthN

  defdelegate setup_required?(), to: AuthN
  defdelegate resolve_channel_actor(adapter, channel_id, external_id), to: AuthN
  defdelegate fetch_session_user(user_id), to: AuthN
  defdelegate match_or_create_from_channel(input), to: AuthN
  defdelegate login_from_provider(input), to: AuthN
  defdelegate create_activation_code(created_by_user, metadata \\ %{}), to: AuthN
  defdelegate revoke_activation_code(activation_code_or_id), to: AuthN
  defdelegate consume_activation_code(plaintext_code, input), to: AuthN
  defdelegate issue_user_channel_auth_code(adapter, channel_id, external_id), to: AuthN
  defdelegate consume_user_channel_auth_code(plaintext_code), to: AuthN

  ## AuthZ

  defdelegate authorize(user, resource, action), to: AuthZ
  defdelegate authorize(user, resource, action, context), to: AuthZ
  defdelegate authorize_permission(user, permission_key), to: AuthZ
  defdelegate authorize_permission(user, permission_key, context), to: AuthZ
  defdelegate allowed?(user, resource, action), to: AuthZ
  defdelegate allowed?(user, resource, action, context), to: AuthZ
  defdelegate list_user_groups(user), to: AuthZ
  defdelegate create_user_group(attrs), to: AuthZ
  defdelegate update_user_group(group_or_id, attrs), to: AuthZ
  defdelegate delete_user_group(group_or_id), to: AuthZ
  defdelegate add_user_to_group(user_or_id, group_or_id), to: AuthZ
  defdelegate remove_user_from_group(user_or_id, group_or_id), to: AuthZ
  defdelegate update_user_status(user_or_id, status), to: AuthN
  defdelegate create_permission_grant(attrs), to: AuthZ
  defdelegate update_permission_grant(grant_or_id, attrs), to: AuthZ
  defdelegate delete_permission_grant(grant_or_id), to: AuthZ
end
