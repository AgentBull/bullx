defmodule BullXAccounts do
  @moduledoc """
  AuthN boundary for durable BullX users and Gateway channel bindings.

  Gateway keeps actors channel-local; callers resolve a BullX identity through
  this facade only when business identity is required.
  """

  alias BullXAccounts.AuthN

  defdelegate resolve_channel_actor(adapter, channel_id, external_id), to: AuthN
  defdelegate fetch_session_user(user_id), to: AuthN
  defdelegate match_or_create_from_channel(input), to: AuthN
  defdelegate login_from_provider(input), to: AuthN
  defdelegate create_activation_code(created_by_user, metadata \\ %{}), to: AuthN
  defdelegate revoke_activation_code(activation_code_or_id), to: AuthN
  defdelegate consume_activation_code(plaintext_code, input), to: AuthN
  defdelegate issue_user_channel_auth_code(adapter, channel_id, external_id), to: AuthN
  defdelegate consume_user_channel_auth_code(plaintext_code), to: AuthN
end
