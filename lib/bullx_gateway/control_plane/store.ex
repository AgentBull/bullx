defmodule BullXGateway.ControlPlane.Store do
  @moduledoc false

  @callback put_trigger_record(map()) :: :ok | {:error, :duplicate | term()}
  @callback fetch_trigger_record_by_dedupe_key(String.t()) :: {:ok, map()} | :error
  @callback list_trigger_records(keyword()) :: {:ok, [map()]}
  @callback update_trigger_record(String.t(), map()) :: :ok | {:error, term()}
  @callback put_dedupe_seen(map()) :: :ok | {:error, term()}
  @callback fetch_dedupe_seen(String.t()) :: {:ok, map()} | :error
  @callback list_active_dedupe_seen() :: {:ok, [map()]}
  @callback delete_expired_dedupe_seen() :: {:ok, non_neg_integer()}
  @callback delete_old_trigger_records(DateTime.t()) :: {:ok, non_neg_integer()}
  @callback transaction((module() -> result)) :: {:ok, result} | {:error, term()} when result: var

  @callback put_dispatch(map()) :: :ok | {:error, term()}
  @callback update_dispatch(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback delete_dispatch(String.t()) :: :ok | {:error, term()}
  @callback fetch_dispatch(String.t()) :: {:ok, map()} | :error
  @callback list_dispatches_by_scope(BullXGateway.Delivery.channel(), String.t(), [term()]) ::
              {:ok, [map()]}
  @callback put_attempt(map()) :: :ok | {:error, term()}
  @callback list_attempts(String.t()) :: {:ok, [map()]}
  @callback put_dead_letter(map()) :: :ok | {:error, term()}
  @callback fetch_dead_letter(String.t()) :: {:ok, map()} | :error
  @callback list_dead_letters(keyword()) :: {:ok, [map()]}
  @callback increment_dead_letter_replay_count(String.t()) :: :ok | {:error, term()}
end
