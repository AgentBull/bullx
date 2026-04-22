defmodule BullXGateway do
  @moduledoc """
  Multi-transport ingress and egress. Normalizes inbound events from external
  sources (HTTP polling, subscribed WebSockets, webhooks, channel adapters like
  Feishu/Slack/Telegram) into internal signals, and dispatches outbound
  messages back to those destinations.
  """

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.ControlPlane.InboundReplay
  alias BullXGateway.Deduper
  alias BullXGateway.Gating
  alias BullXGateway.Json
  alias BullXGateway.Moderation
  alias BullXGateway.Security
  alias BullXGateway.SignalContext
  alias BullXGateway.Signals.InboundReceived
  alias Jido.Signal
  alias Jido.Signal.Bus

  @type inbound_input ::
          BullXGateway.Inputs.Message.t()
          | BullXGateway.Inputs.MessageEdited.t()
          | BullXGateway.Inputs.MessageRecalled.t()
          | BullXGateway.Inputs.Reaction.t()
          | BullXGateway.Inputs.Action.t()
          | BullXGateway.Inputs.SlashCommand.t()
          | BullXGateway.Inputs.Trigger.t()

  @spec publish_inbound(inbound_input(), keyword()) ::
          {:ok, :published}
          | {:ok, :duplicate}
          | {:error, {:invalid_input, term()}}
          | {:error, {:security_denied, :verify, atom(), String.t()}}
          | {:error, {:policy_denied, :gating | :moderation, atom(), String.t()}}
          | {:error, {:moderation_invalid_return, module(), term()}}
          | {:error, {:bus_publish_failed, term()}}
          | {:error, {:store_unavailable, term()}}
  def publish_inbound(input, opts \\ []) do
    metadata = %{source: Map.get(input, :source), id: Map.get(input, :id)}

    :telemetry.span([:bullx, :gateway, :publish_inbound], metadata, fn ->
      result = do_publish_inbound(input, opts)
      {result, %{policy_outcome: telemetry_outcome(result)}}
    end)
  end

  defp do_publish_inbound(input, opts) do
    gateway_config = Application.get_env(:bullx, __MODULE__, [])

    policy_timeout_fallback =
      Keyword.get(
        opts,
        :policy_timeout_fallback,
        Keyword.get(gateway_config, :policy_timeout_fallback, :deny)
      )

    policy_error_fallback =
      Keyword.get(
        opts,
        :policy_error_fallback,
        Keyword.get(gateway_config, :policy_error_fallback, :deny)
      )

    with {:ok, signal} <- inbound_signal(input),
         {:ok, signal} <-
           verify_sender(
             signal,
             input,
             stage_config(gateway_config, opts, :security),
             policy_timeout_fallback,
             policy_error_fallback
           ),
         false <- Deduper.seen?(signal.source, signal.id),
         {:ok, ctx} <- SignalContext.from_signal(signal),
         {:ok, gating_flags} <-
           run_gating(
             ctx,
             stage_config(gateway_config, opts, :gating),
             policy_timeout_fallback,
             policy_error_fallback
           ),
         {:ok, signal, moderation_flags, modified?} <-
           run_moderation(
             signal,
             stage_config(gateway_config, opts, :moderation),
             policy_timeout_fallback,
             policy_error_fallback
           ),
         {:ok, signal} <- put_flags(signal, gating_flags ++ moderation_flags),
         {:ok, signal} <- maybe_put_modified(signal, modified?),
         {:ok, record} <- persist_trigger(signal),
         :ok <- publish_signal(signal),
         {:ok, :published} <- finalize_publish(record, ttl_ms_for(input.channel)) do
      {:ok, :published}
    else
      true ->
        {:ok, :duplicate}

      {:error, :duplicate} ->
        handle_unpublished_duplicate(input)

      {:error, _} = error ->
        error

      other ->
        {:error, {:invalid_input, other}}
    end
  end

  defp inbound_signal(input) do
    case InboundReceived.new(input) do
      {:ok, signal} -> {:ok, signal}
      {:error, reason} -> {:error, {:invalid_input, reason}}
    end
  end

  defp verify_sender(signal, input, security_config, timeout_fallback, error_fallback) do
    case Security.verify_sender(
           input.channel,
           input,
           security_config,
           timeout_fallback,
           error_fallback
         ) do
      :ok ->
        {:ok, signal}

      {:ok, metadata} ->
        put_security_metadata(signal, metadata)

      {:deny, reason, description} ->
        {:error, {:security_denied, :verify, reason, description}}
    end
  end

  defp run_gating(ctx, gating_config, timeout_fallback, error_fallback) do
    case Gating.run_checks(
           ctx,
           Keyword.get(gating_config, :gaters, []),
           Keyword.get(gating_config, :gating_opts, []),
           timeout_ms: Keyword.get(gating_config, :gating_timeout_ms, 50),
           timeout_fallback: timeout_fallback,
           error_fallback: error_fallback
         ) do
      {:ok, flags} -> {:ok, flags}
      {:deny, reason, description} -> {:error, {:policy_denied, :gating, reason, description}}
    end
  end

  defp run_moderation(signal, moderation_config, timeout_fallback, error_fallback) do
    case Moderation.apply_moderators(
           signal,
           Keyword.get(moderation_config, :moderators, []),
           Keyword.get(moderation_config, :moderation_opts, []),
           timeout_ms: Keyword.get(moderation_config, :moderation_timeout_ms, 100),
           timeout_fallback: timeout_fallback,
           error_fallback: error_fallback,
           validate: &InboundReceived.validate_signal/1
         ) do
      {:ok, moderated_signal, flags, modified?} ->
        {:ok, moderated_signal, flags, modified?}

      {:reject, reason, description} ->
        {:error, {:policy_denied, :moderation, reason, description}}

      {:error, {:invalid_return, module, detail}} ->
        {:error, {:moderation_invalid_return, module, detail}}
    end
  end

  defp put_security_metadata(signal, metadata) do
    with {:ok, normalized} <- Json.normalize(metadata),
         {:ok, updated_signal} <-
           InboundReceived.validate_signal(%{
             signal
             | extensions: Map.put(signal.extensions || %{}, "bullx_security", normalized)
           }) do
      {:ok, updated_signal}
    else
      {:error, reason} ->
        {:error, {:security_denied, :verify, :invalid_metadata, inspect(reason)}}
    end
  end

  defp put_flags(signal, []), do: {:ok, signal}

  defp put_flags(signal, flags) do
    existing_flags = Map.get(signal.extensions || %{}, "bullx_flags", [])

    with {:ok, normalized} <- Json.normalize(existing_flags ++ flags),
         {:ok, updated_signal} <-
           InboundReceived.validate_signal(%{
             signal
             | extensions: Map.put(signal.extensions || %{}, "bullx_flags", normalized)
           }) do
      {:ok, updated_signal}
    end
  end

  defp maybe_put_modified(signal, false), do: {:ok, signal}

  defp maybe_put_modified(signal, true) do
    InboundReceived.validate_signal(%{
      signal
      | extensions: Map.put(signal.extensions || %{}, "bullx_moderation_modified", true)
    })
  end

  defp persist_trigger(%Signal{} = signal) do
    record = trigger_record(signal)

    case ControlPlane.transaction(fn store -> store.put_trigger_record(record) end) do
      {:ok, :ok} ->
        case ControlPlane.fetch_trigger_record_by_dedupe_key(record.dedupe_key) do
          {:ok, persisted_record} -> {:ok, persisted_record}
          :error -> {:error, {:store_unavailable, :missing_trigger_record}}
        end

      {:error, :duplicate} ->
        {:error, :duplicate}

      {:error, reason} ->
        {:error, {:store_unavailable, reason}}
    end
  end

  defp handle_unpublished_duplicate(input) do
    dedupe_key = BullXGateway.DedupeKey.generate(input.source, input.id)

    case ControlPlane.fetch_trigger_record_by_dedupe_key(dedupe_key) do
      {:ok, %{published_at: %DateTime{}} = record} ->
        finalize_already_published_duplicate(record, ttl_ms_for(input.channel))

      {:ok, record} ->
        republish_duplicate_record(record, ttl_ms_for(input.channel))

      :error ->
        {:error, {:store_unavailable, :missing_trigger_record}}
    end
  end

  defp republish_duplicate_record(record, ttl_ms) do
    with {:ok, signal} <- Signal.from_map(record.signal_envelope),
         :ok <- publish_signal(signal),
         {:ok, :published} <- finalize_publish(record, ttl_ms) do
      {:ok, :published}
    end
  end

  defp finalize_already_published_duplicate(record, ttl_ms) do
    case Deduper.mark_seen(record.source, record.external_id, ttl_ms) do
      :ok -> {:ok, :duplicate}
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  end

  defp publish_signal(signal) do
    case Bus.publish(BullXGateway.SignalBus, [signal]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        InboundReplay.run_once()
        {:error, {:bus_publish_failed, reason}}
    end
  end

  defp finalize_publish(record, ttl_ms) do
    now = DateTime.utc_now()

    case ControlPlane.update_trigger_record(record.id, %{published_at: now}) do
      :ok ->
        case Deduper.mark_seen(record.source, record.external_id, ttl_ms) do
          :ok -> {:ok, :published}
          {:error, reason} -> {:error, {:store_unavailable, reason}}
        end

      {:error, reason} ->
        InboundReplay.run_once()
        {:error, {:store_unavailable, reason}}
    end
  end

  defp trigger_record(signal) do
    dedupe_key = BullXGateway.DedupeKey.generate(signal.source, signal.id)

    %{
      source: signal.source,
      external_id: signal.id,
      dedupe_key: dedupe_key,
      signal_id: signal.id,
      signal_type: signal.type,
      event_category: signal.data["event_category"],
      duplex: signal.data["duplex"],
      channel_adapter: signal.extensions["bullx_channel_adapter"],
      channel_tenant: signal.extensions["bullx_channel_tenant"],
      scope_id: signal.data["scope_id"],
      thread_id: signal.data["thread_id"],
      signal_envelope: signal_to_map(signal),
      policy_outcome: "published"
    }
  end

  defp signal_to_map(signal) do
    signal
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp stage_config(gateway_config, opts, stage) do
    Keyword.merge(Keyword.get(gateway_config, stage, []), Keyword.get(opts, stage, []))
  end

  defp ttl_ms_for(channel) do
    AdapterRegistry.dedupe_ttl_ms(channel)
  end

  defp telemetry_outcome({:ok, :published}), do: :published
  defp telemetry_outcome({:ok, :duplicate}), do: :duplicate
  defp telemetry_outcome({:error, {:security_denied, _, _, _}}), do: :denied_security
  defp telemetry_outcome({:error, {:policy_denied, :gating, _, _}}), do: :denied_gating
  defp telemetry_outcome({:error, {:policy_denied, :moderation, _, _}}), do: :rejected_moderation
  defp telemetry_outcome(_), do: :error
end
