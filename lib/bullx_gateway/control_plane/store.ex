defmodule BullXGateway.ControlPlane.Store do
  @moduledoc false

  @callback put_dedupe_seen(map()) :: :ok | {:error, term()}
  @callback fetch_dedupe_seen(String.t()) :: {:ok, map()} | :error
  @callback list_active_dedupe_seen() :: {:ok, [map()]}
  @callback delete_expired_dedupe_seen() :: {:ok, non_neg_integer()}

  @callback put_dead_letter(map()) :: :ok | {:error, term()}
  @callback fetch_dead_letter(String.t()) :: {:ok, map()} | :error
  @callback list_dead_letters(keyword()) :: {:ok, [map()]}
  @callback increment_dead_letter_replay_count(String.t()) :: :ok | {:error, term()}
  @callback delete_old_dead_letters(DateTime.t()) :: {:ok, non_neg_integer()}

  @callback transaction((module() -> result)) :: {:ok, result} | {:error, term()} when result: var
end
