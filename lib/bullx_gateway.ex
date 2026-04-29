defmodule BullXGateway do
  @moduledoc """
  Multi-transport ingress and egress. Normalizes inbound events from external
  sources (HTTP polling, subscribed WebSockets, webhooks, channel adapters like
  Feishu/Slack/Telegram) into internal signals, and dispatches outbound
  messages back to those destinations.
  """

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.Deduper
  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Outcome
  alias BullXGateway.DLQ.ReplayWorker
  alias BullXGateway.Gating
  alias BullXGateway.Json
  alias BullXGateway.Moderation
  alias BullXGateway.OutboundDeduper
  alias BullXGateway.ScopeWorker
  alias BullXGateway.Security
  alias BullXGateway.SignalContext
  alias BullXGateway.Signals.InboundReceived
  alias BullX.Config.Gateway, as: GatewayConfig
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
    gateway_config = GatewayConfig.config()

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
         :ok <- publish_signal(signal),
         :ok <- mark_seen(input) do
      {:ok, :published}
    else
      true ->
        {:ok, :duplicate}

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

  defp publish_signal(signal) do
    case Bus.publish(BullXGateway.SignalBus, [signal]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, {:bus_publish_failed, reason}}
    end
  end

  defp mark_seen(input) do
    ttl_ms = ttl_ms_for(input.channel)

    case Deduper.mark_seen(input.source, input.id, ttl_ms) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
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

  # ---------------------------------------------------------------------------
  # Egress (RFC 0003)
  # ---------------------------------------------------------------------------

  @type delivery_error ::
          {:invalid_delivery, term()}
          | {:unknown_channel, Delivery.channel()}
          | {:security_denied, :sanitize, atom(), String.t()}
          | {:store_unavailable, term()}
          | {:bus_publish_failed, term()}
          | {:enqueue_failed, term()}

  @spec deliver(Delivery.t() | term(), keyword()) ::
          {:ok, String.t()} | {:error, delivery_error()}
  def deliver(delivery, opts \\ [])

  def deliver(%Delivery{} = delivery, opts) do
    metadata = %{
      delivery_id: delivery.id,
      op: delivery.op,
      channel: delivery.channel,
      scope_id: delivery.scope_id
    }

    :telemetry.span([:bullx, :gateway, :deliver], metadata, fn ->
      result = do_deliver(delivery, opts)
      {result, %{outcome: deliver_telemetry_outcome(result)}}
    end)
  end

  def deliver(other, _opts) do
    {:error, {:invalid_delivery, {:not_a_delivery, other}}}
  end

  @spec cancel_stream(String.t()) :: :ok | {:error, :not_found}
  def cancel_stream(delivery_id) when is_binary(delivery_id) do
    ScopeWorker.cancel_stream(delivery_id)
  end

  @spec stream_supported?(Delivery.channel()) :: boolean()
  def stream_supported?(channel) do
    case lookup_channel(channel) do
      {:ok, %{module: module}} -> adapter_supports_stream?(module)
      {:error, _reason} -> false
    end
  end

  @spec replay_dead_letter(String.t()) ::
          {:ok, %{status: :replayed, delivery: Delivery.t()}} | {:error, :not_found | term()}
  def replay_dead_letter(dispatch_id) when is_binary(dispatch_id) do
    ReplayWorker.replay(dispatch_id)
  end

  @spec list_dead_letters(keyword()) :: {:ok, [map()]}
  def list_dead_letters(opts \\ []) do
    ControlPlane.list_dead_letters(opts)
  end

  @spec purge_dead_letter(String.t()) :: :ok | {:error, term()}
  def purge_dead_letter(dispatch_id) when is_binary(dispatch_id) do
    ControlPlane.purge_dead_letter(dispatch_id)
  end

  defp do_deliver(delivery, opts) do
    gateway_config = GatewayConfig.config()

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

    with :ok <- validate_delivery(delivery),
         {:ok, adapter_entry} <- lookup_channel(delivery.channel),
         :ok <- precheck_capabilities(delivery, adapter_entry),
         {:ok, delivery} <-
           sanitize(
             delivery,
             stage_config(gateway_config, opts, :security),
             policy_timeout_fallback,
             policy_error_fallback
           ) do
      case OutboundDeduper.seen?(delivery.id) do
        {:hit, cached_outcome} ->
          publish_duplicate_success(delivery, cached_outcome)
          {:ok, delivery.id}

        :miss ->
          case ScopeWorker.enqueue(delivery.channel, delivery.scope_id, delivery) do
            :ok -> {:ok, delivery.id}
            {:error, reason} -> {:error, {:enqueue_failed, reason}}
          end
      end
    else
      {:capability_unsupported, reason} ->
        case publish_unsupported_failure(delivery, reason) do
          :ok -> {:ok, delivery.id}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_delivery(delivery) do
    case Delivery.validate(delivery) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_delivery, reason}}
    end
  end

  defp lookup_channel(channel) do
    case AdapterRegistry.lookup(channel) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_channel, channel}}
    end
  end

  defp precheck_capabilities(delivery, adapter_entry) do
    module = adapter_entry.module

    cond do
      not function_exported?(module, :capabilities, 0) ->
        {:capability_unsupported, {:op, delivery.op}}

      delivery.op in module.capabilities() ->
        :ok

      true ->
        {:capability_unsupported, {:op, delivery.op}}
    end
  end

  defp adapter_supports_stream?(module) do
    function_exported?(module, :capabilities, 0) and :stream in module.capabilities()
  end

  defp sanitize(delivery, security_config, timeout_fallback, error_fallback) do
    case Security.sanitize_outbound(
           delivery.channel,
           delivery,
           security_config,
           timeout_fallback,
           error_fallback
         ) do
      {:ok, %Delivery{} = sanitized} -> {:ok, sanitized}
      {:ok, %Delivery{} = sanitized, _metadata} -> {:ok, sanitized}
      {:error, {:security_denied, _, _, _} = reason} -> {:error, reason}
    end
  end

  defp publish_unsupported_failure(delivery, {:op, op}) do
    error_map = %{
      "kind" => "unsupported",
      "message" => "Adapter does not declare op-capability #{inspect(op)}",
      "details" => %{"op" => Atom.to_string(op)}
    }

    outcome = Outcome.new_failure(delivery.id, error_map)

    now = DateTime.utc_now()

    with :ok <-
           ControlPlane.put_dead_letter(%{
             dispatch_id: delivery.id,
             op: Atom.to_string(delivery.op),
             channel_adapter: Atom.to_string(elem(delivery.channel, 0)),
             channel_id: elem(delivery.channel, 1),
             scope_id: delivery.scope_id,
             thread_id: delivery.thread_id,
             caused_by_signal_id: delivery.caused_by_signal_id,
             payload: ScopeWorker.encode_delivery_payload(delivery),
             final_error: error_map,
             attempts_total: 0,
             dead_lettered_at: now
           }),
         :ok <- publish_delivery_signal(delivery, outcome) do
      :ok
    else
      {:error, {:bus_publish_failed, _}} = error -> error
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  end

  defp publish_duplicate_success(delivery, %Outcome{} = cached_outcome) do
    outcome = Outcome.append_warnings(cached_outcome, ["duplicate_delivery_id"])
    publish_delivery_signal(delivery, outcome)
  end

  defp publish_delivery_signal(delivery, %Outcome{} = outcome) do
    {adapter, channel_id} = delivery.channel

    type =
      case outcome.status do
        :failed -> "com.agentbull.x.delivery.failed"
        _ -> "com.agentbull.x.delivery.succeeded"
      end

    subject = render_delivery_subject(adapter, delivery.scope_id, delivery.thread_id)

    extensions =
      %{
        "bullx_channel_adapter" => Atom.to_string(adapter),
        "bullx_channel_id" => channel_id
      }

    extensions =
      case delivery.caused_by_signal_id do
        nil -> extensions
        id -> Map.put(extensions, "bullx_caused_by", id)
      end

    attrs = %{
      id: Signal.ID.generate!(),
      source: "bullx://gateway/#{adapter}/#{channel_id}",
      type: type,
      subject: subject,
      time: DateTime.to_iso8601(DateTime.utc_now()),
      datacontenttype: "application/json",
      data: Outcome.to_signal_data(outcome),
      extensions: extensions
    }

    with {:ok, signal} <- Signal.new(attrs),
         {:ok, _} <- Bus.publish(BullXGateway.SignalBus, [signal]) do
      :ok
    else
      {:error, reason} -> {:error, {:bus_publish_failed, reason}}
    end
  end

  defp render_delivery_subject(adapter, scope_id, nil), do: "#{adapter}:#{scope_id}"

  defp render_delivery_subject(adapter, scope_id, thread_id),
    do: "#{adapter}:#{scope_id}:#{thread_id}"

  defp deliver_telemetry_outcome({:ok, _}), do: :accepted
  defp deliver_telemetry_outcome({:error, {:invalid_delivery, _}}), do: :invalid_delivery
  defp deliver_telemetry_outcome({:error, {:unknown_channel, _}}), do: :unknown_channel
  defp deliver_telemetry_outcome({:error, {:security_denied, _, _, _}}), do: :security_denied
  defp deliver_telemetry_outcome(_), do: :error
end
