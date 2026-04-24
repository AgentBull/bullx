defmodule BullXFeishu.EventListener do
  @moduledoc false

  require Logger

  alias BullXFeishu.{Cache, DirectCommand, EventMapper}
  alias FeishuOpenAPI.{CardAction, Event}

  def handle_event(event_type, %Event{} = event, state) do
    log_inbound(event_type, event, state)

    case EventMapper.map_event(event_type, event, state.config) do
      {:ignore, reason} ->
        log_result(:ignored, reason, event_type, event, state)
        {:ok, %{status: :ignored, reason: reason}, state}

      {:direct_command, command} ->
        handle_direct_command(command, state)

      {:ok, mapped} ->
        publish_mapped(mapped, event_type, event, state)

      {:error, error} ->
        log_result(:mapping_failed, error["kind"], event_type, event, state)
        {{:error, error}, state}
    end
  end

  def handle_card_action(%CardAction{} = action, state) do
    case EventMapper.map_card_action(action, state.config) do
      {:ok, %{dedupe_key: dedupe_key} = mapped} ->
        {seen?, cache} =
          Cache.seen_card_action?(
            state.cache,
            dedupe_key,
            state.config.card_action_dedupe_ttl_ms
          )

        state = %{state | cache: cache}

        if seen? do
          {{:ok, %{status: :duplicate}}, state}
        else
          publish_mapped(mapped, "card.action.trigger", nil, state)
        end

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp handle_direct_command(command, state) do
    case DirectCommand.handle(command, state.config, state.cache) do
      {:ok, result, cache} ->
        Logger.info("feishu direct command handled",
          channel: :feishu,
          channel_id: state.config.channel_id,
          command_name: command.name,
          scope_id: command.chat_id,
          reply_to_external_id: command.message_id
        )

        {{:ok, result}, %{state | cache: cache}}

      {:error, error, cache} ->
        {{:error, error}, %{state | cache: cache}}
    end
  end

  defp publish_mapped(
         %{account_input: account_input, input: input} = mapped,
         event_type,
         event,
         state
       ) do
    case state.config.accounts_module.match_or_create_from_channel(account_input) do
      {:ok, _user, _binding} ->
        do_publish(input, mapped, event_type, event, state)

      {:error, :activation_required} ->
        text = activation_required_text(mapped)
        command = synthetic_reply_command(mapped, state, "activation_required")
        handle_direct_reply(command, state, text, "activation_required")

      {:error, :user_banned} ->
        text = BullX.I18n.t("gateway.feishu.auth.denied")
        command = synthetic_reply_command(mapped, state, "denied")
        handle_direct_reply(command, state, text, "denied")

      {:error, reason} ->
        {{:error, BullXFeishu.Error.map(reason)}, state}
    end
  end

  defp do_publish(input, mapped, event_type, event, state) do
    result = state.config.gateway_module.publish_inbound(input)

    log_result(elem(result, 0), result, event_type, event, state)

    state = maybe_store_message_context(mapped, state)
    {result, state}
  end

  defp handle_direct_reply(command, state, text, command_name) do
    case DirectCommand.reply_text(command, state.config, state.cache, text, command_name) do
      {:ok, result, cache} -> {{:ok, result}, %{state | cache: cache}}
      {:error, error, cache} -> {{:error, error}, %{state | cache: cache}}
    end
  end

  defp maybe_store_message_context(%{context: %{message_id: message_id} = context}, state)
       when is_binary(message_id) do
    cache =
      Cache.put_message_context(
        state.cache,
        message_id,
        context,
        state.config.message_context_ttl_ms
      )

    %{state | cache: cache}
  end

  defp maybe_store_message_context(_mapped, state), do: state

  defp activation_required_text(%{context: %{chat_type: "p2p"}}) do
    BullX.I18n.t("gateway.feishu.auth.activation_required")
  end

  defp activation_required_text(_mapped),
    do: BullX.I18n.t("gateway.feishu.auth.direct_command_dm_only")

  defp synthetic_reply_command(%{context: context}, state, command_name) do
    %{
      name: command_name,
      args: "",
      event_id: "#{context.event_id}:#{command_name}",
      channel: state.config.channel,
      channel_id: state.config.channel_id,
      chat_id: context.chat_id,
      chat_type: context.chat_type,
      thread_id: nil,
      message_id: context.message_id,
      actor: context.actor,
      account_input: context.account_input,
      source: "bullx://gateway/feishu/#{state.config.channel_id}"
    }
  end

  defp log_inbound(event_type, %Event{} = event, state) do
    Logger.info("feishu inbound event received",
      channel: :feishu,
      channel_id: state.config.channel_id,
      event_type: event_type,
      event_id: event.id
    )
  end

  defp log_result(status, detail, event_type, event, state) do
    Logger.info("feishu inbound result",
      channel: :feishu,
      channel_id: state.config.channel_id,
      event_type: event_type,
      event_id: if(match?(%Event{}, event), do: event.id, else: nil),
      status: status,
      detail: inspect(detail)
    )
  end
end
