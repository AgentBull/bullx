defmodule BullXFeishu.EventMapper do
  @moduledoc """
  Normalizes Feishu events and card actions into Gateway inputs.
  """

  alias BullXGateway.Inputs.{
    Action,
    Message,
    MessageEdited,
    MessageRecalled,
    Reaction,
    SlashCommand
  }

  alias BullXFeishu.{Config, ContentMapper, DirectCommand}
  alias FeishuOpenAPI.{CardAction, Event}

  @message_receive "im.message.receive_v1"
  @message_updated "im.message.updated_v1"
  @message_recalled "im.message.recalled_v1"
  @reaction_created "im.message.reaction.created_v1"
  @reaction_deleted "im.message.reaction.deleted_v1"

  @type result ::
          {:ok, map()}
          | {:direct_command, DirectCommand.command()}
          | {:ignore, atom()}
          | {:error, map()}

  @spec map_event(String.t(), Event.t(), Config.t()) :: result()
  def map_event(@message_receive, %Event{} = event, %Config{} = config) do
    with {:ok, env} <- common_event_env(event, config),
         :ok <- reject_self_sent(env, config),
         {:ok, blocks} <- ContentMapper.from_message(env.message, config),
         text <- ContentMapper.primary_text(blocks),
         {:ok, actor} <- actor_from_sender(env.sender),
         profile <- profile_from_sender(env.sender),
         account_input <- account_input(config, actor.id, profile, env),
         context <- context(env, actor, blocks, account_input) do
      maybe_message_or_command(text, env, actor, blocks, context, config)
    end
  end

  def map_event(@message_updated, %Event{} = event, %Config{} = config) do
    with {:ok, env} <- common_event_env(event, config),
         :ok <- reject_self_sent(env, config),
         {:ok, blocks} <- ContentMapper.from_message(env.message, config),
         {:ok, actor} <- actor_from_sender(env.sender),
         account_input <- account_input(config, actor.id, profile_from_sender(env.sender), env) do
      {:ok,
       %{
         input: %MessageEdited{
           id: event.id || "#{@message_updated}:#{env.message_id}:#{env.update_time || now_ms()}",
           source: source(config),
           channel: config.channel,
           scope_id: env.chat_id,
           thread_id: env.thread_id,
           actor: gateway_actor(actor),
           event: gateway_event(@message_updated, event, env),
           reply_channel: reply_channel(config, env),
           target_external_message_id: env.message_id,
           edited_at: event.created_at,
           refs: refs(event, env),
           content: blocks
         },
         account_input: account_input,
         context: context(env, actor, blocks, account_input)
       }}
    end
  end

  def map_event(@message_recalled, %Event{} = event, %Config{} = config) do
    with {:ok, env} <- common_event_env(event, config),
         {:ok, actor} <- actor_from_sender(env.sender),
         account_input <- account_input(config, actor.id, profile_from_sender(env.sender), env) do
      recalled_at = event.created_at

      {:ok,
       %{
         input: %MessageRecalled{
           id:
             event.id || "#{@message_recalled}:#{env.message_id}:#{env.recall_time || now_ms()}",
           source: source(config),
           channel: config.channel,
           scope_id: env.chat_id,
           thread_id: env.thread_id,
           actor: gateway_actor(actor),
           event: gateway_event(@message_recalled, event, env),
           reply_channel: reply_channel(config, env),
           target_external_message_id: env.message_id,
           recalled_by_actor: gateway_actor(actor),
           recalled_at: recalled_at,
           refs: refs(event, env)
         },
         account_input: account_input,
         context: context(env, actor, [], account_input)
       }}
    end
  end

  def map_event(type, %Event{} = event, %Config{} = config)
      when type in [@reaction_created, @reaction_deleted] do
    with {:ok, env} <- common_event_env(event, config),
         {:ok, actor} <- actor_from_sender(env.sender),
         account_input <- account_input(config, actor.id, profile_from_sender(env.sender), env),
         emoji <- reaction_emoji(env.raw_event) do
      action = if type == @reaction_created, do: :added, else: :removed

      {:ok,
       %{
         input: %Reaction{
           id:
             event.id ||
               "#{type}:#{env.message_id}:#{actor.open_id}:#{emoji}:#{env.action_time || now_ms()}",
           source: source(config),
           channel: config.channel,
           scope_id: env.chat_id,
           thread_id: env.thread_id,
           actor: gateway_actor(actor),
           event: gateway_event(type, event, env),
           reply_channel: reply_channel(config, env),
           target_external_message_id: env.message_id,
           emoji: emoji,
           action: action,
           refs: refs(event, env)
         },
         account_input: account_input,
         context: context(env, actor, [], account_input)
       }}
    end
  end

  def map_event("app_ticket", %Event{}, %Config{}), do: {:ignore, :sdk_lifecycle_event}
  def map_event(_type, %Event{}, %Config{}), do: {:ignore, :unhandled_event}

  @spec map_card_action(CardAction.t(), Config.t()) :: result()
  def map_card_action(%CardAction{} = action, %Config{} = config) do
    with {:ok, actor} <-
           actor_from_ids(%{"open_id" => action.open_id, "user_id" => action.user_id}),
         env <- card_env(action, config),
         account_input <- account_input(config, actor.id, profile_from_card(action), env) do
      action_id = action_id(action)
      dedupe_key = action.token || "#{action.open_message_id}:#{action_id}:#{actor.open_id}"

      {:ok,
       %{
         dedupe_key: dedupe_key,
         input: %Action{
           id: "card_action:#{action.open_message_id}:#{action_id}:#{actor.open_id}",
           source: source(config),
           channel: config.channel,
           scope_id: env.chat_id,
           thread_id: nil,
           actor: gateway_actor(actor),
           event: gateway_card_event(action, env),
           reply_channel: reply_channel(config, env),
           target_external_message_id: action.open_message_id,
           action_id: action_id,
           values: action_values(action),
           refs: refs(nil, env)
         },
         account_input: account_input,
         context: context(env, actor, [], account_input)
       }}
    end
  end

  defp maybe_message_or_command(text, env, actor, blocks, context, config) do
    case DirectCommand.parse(text) do
      {:ok, %{name: name} = parsed} when name in ["ping", "preauth", "web_auth"] ->
        {:direct_command,
         Map.merge(parsed, %{
           event_id: env.event_id,
           channel: config.channel,
           channel_id: config.channel_id,
           chat_id: env.chat_id,
           chat_type: env.chat_type,
           thread_id: env.thread_id,
           message_id: env.message_id,
           actor: actor,
           account_input: context.account_input,
           source: source(config)
         })}

      {:ok, %{name: name, args: args}} ->
        {:ok,
         %{
           input: %SlashCommand{
             id: env.event_id,
             source: source(config),
             channel: config.channel,
             scope_id: env.chat_id,
             thread_id: env.thread_id,
             actor: gateway_actor(actor),
             event: gateway_event(@message_receive, env.event, env),
             reply_channel: reply_channel(config, env),
             command_name: name,
             args: args,
             reply_to_external_id: env.message_id,
             refs: refs(env.event, env),
             content: blocks
           },
           account_input: context.account_input,
           context: context
         }}

      :error ->
        {:ok,
         %{
           input: %Message{
             id: env.event_id,
             source: source(config),
             channel: config.channel,
             scope_id: env.chat_id,
             thread_id: env.thread_id,
             actor: gateway_actor(actor),
             event: gateway_event(@message_receive, env.event, env),
             reply_channel: reply_channel(config, env),
             reply_to_external_id: env.reply_to_external_id,
             refs: refs(env.event, env),
             content: blocks
           },
           account_input: context.account_input,
           context: context
         }}
    end
  end

  defp common_event_env(%Event{} = event, %Config{} = config) do
    raw_event = event.content || %{}
    message = Map.get(raw_event, "message") || raw_event
    sender = Map.get(raw_event, "sender") || Map.get(raw_event, "operator") || %{}

    chat_id =
      Map.get(message, "chat_id") ||
        Map.get(raw_event, "chat_id") ||
        Map.get(raw_event, "open_chat_id")

    message_id =
      Map.get(message, "message_id") ||
        Map.get(message, "open_message_id") ||
        Map.get(raw_event, "message_id") ||
        Map.get(raw_event, "open_message_id")

    if present?(chat_id) and present?(message_id) do
      {:ok,
       %{
         event: event,
         raw_event: raw_event,
         event_id: event.id || message_id,
         event_type: event.type,
         tenant_key: event.tenant_key || Map.get(raw_event, "tenant_key"),
         app_id: event.app_id || config.app_id,
         message: message,
         sender: sender,
         chat_id: chat_id,
         chat_type: Map.get(message, "chat_type") || Map.get(raw_event, "chat_type"),
         message_id: message_id,
         open_message_id:
           Map.get(message, "open_message_id") || Map.get(raw_event, "open_message_id"),
         thread_id: Map.get(message, "thread_id"),
         reply_to_external_id: Map.get(message, "parent_id") || Map.get(message, "root_id"),
         update_time: Map.get(message, "update_time") || Map.get(raw_event, "update_time"),
         recall_time: Map.get(raw_event, "recall_time"),
         action_time: Map.get(raw_event, "action_time")
       }}
    else
      {:error, BullXFeishu.Error.payload("Feishu event is missing chat_id or message_id")}
    end
  end

  defp card_env(%CardAction{} = action, %Config{} = config) do
    %{
      raw_event: action.raw,
      event_id: action.token || action.open_message_id,
      event_type: "card.action.trigger",
      tenant_key: action.tenant_key,
      app_id: config.app_id,
      chat_id: action.open_chat_id || "unknown",
      chat_type: nil,
      message_id: action.open_message_id,
      open_message_id: action.open_message_id,
      thread_id: nil
    }
  end

  defp reject_self_sent(%{sender: sender}, %Config{} = config) do
    sender_type = Map.get(sender, "sender_type")
    ids = sender_ids(sender)

    cond do
      sender_type not in ["bot", "app"] ->
        :ok

      present?(config.bot_open_id) and ids["open_id"] == config.bot_open_id ->
        {:ignore, :self_sent_bot_message}

      present?(config.bot_user_id) and ids["user_id"] == config.bot_user_id ->
        {:ignore, :self_sent_bot_message}

      true ->
        :ok
    end
  end

  defp actor_from_sender(sender),
    do: actor_from_ids(sender_ids(sender), profile_from_sender(sender))

  defp actor_from_ids(ids, profile \\ %{}) do
    case Map.get(ids, "open_id") do
      open_id when is_binary(open_id) and open_id != "" ->
        {:ok,
         %{
           id: "feishu:" <> open_id,
           open_id: open_id,
           user_id: Map.get(ids, "user_id"),
           union_id: Map.get(ids, "union_id"),
           display: profile["display_name"] || profile["name"] || open_id,
           bot: false
         }}

      _ ->
        {:error,
         BullXFeishu.Error.payload(BullX.I18n.t("gateway.feishu.errors.profile_unavailable"))}
    end
  end

  defp sender_ids(%{"sender_id" => ids}) when is_map(ids), do: ids
  defp sender_ids(%{"operator_id" => ids}) when is_map(ids), do: ids
  defp sender_ids(map) when is_map(map), do: map
  defp sender_ids(_), do: %{}

  defp profile_from_sender(sender) when is_map(sender) do
    ids = sender_ids(sender)

    %{}
    |> maybe_put("display_name", first_string(sender, ["name", "display_name", "sender_name"]))
    |> maybe_put("avatar_url", first_string(sender, ["avatar_url", "avatar"]))
    |> maybe_put("email", first_string(sender, ["email"]))
    |> maybe_put_phone(first_string(sender, ["mobile", "phone"]))
    |> maybe_put("open_id", ids["open_id"])
    |> maybe_put("union_id", ids["union_id"])
    |> maybe_put("user_id", ids["user_id"])
    |> maybe_put("tenant_key", first_string(sender, ["tenant_key"]))
  end

  defp profile_from_card(%CardAction{} = action) do
    %{}
    |> maybe_put("open_id", action.open_id)
    |> maybe_put("user_id", action.user_id)
    |> maybe_put("tenant_key", action.tenant_key)
  end

  defp account_input(%Config{} = config, external_id, profile, env) do
    %{
      adapter: :feishu,
      channel_id: config.channel_id,
      external_id: external_id,
      profile: profile,
      metadata: %{
        "source" => "feishu_im",
        "tenant_key" => Map.get(env, :tenant_key),
        "chat_id" => Map.get(env, :chat_id),
        "chat_type" => Map.get(env, :chat_type)
      }
    }
  end

  defp context(env, actor, blocks, account_input) do
    %{
      event_id: env.event_id,
      event_type: env.event_type,
      scope_id: env.chat_id,
      chat_id: env.chat_id,
      chat_type: env.chat_type,
      message_id: env.message_id,
      actor: actor,
      content: blocks,
      account_input: account_input
    }
  end

  defp gateway_actor(actor), do: %{id: actor.id, display: actor.display, bot: actor.bot}

  defp gateway_event(type, %Event{} = event, env) do
    %{
      name: type,
      version: 1,
      data: %{
        "feishu" => feishu_data(event, env)
      }
    }
  end

  defp gateway_card_event(%CardAction{} = action, env) do
    %{
      name: "card.action.trigger",
      version: 1,
      data: %{
        "feishu" => %{
          "tenant_key" => action.tenant_key,
          "event_type" => "card.action.trigger",
          "event_id" => env.event_id,
          "open_message_id" => action.open_message_id,
          "chat_id" => action.open_chat_id
        }
      }
    }
  end

  defp feishu_data(%Event{} = event, env) do
    %{
      "tenant_key" => env.tenant_key,
      "app_id" => env.app_id,
      "event_type" => event.type,
      "event_id" => event.id || env.event_id,
      "message_id" => env.message_id,
      "open_message_id" => env.open_message_id,
      "chat_id" => env.chat_id,
      "chat_type" => env.chat_type
    }
    |> reject_nil_values()
  end

  defp refs(nil, env),
    do: refs_from_data(feishu_data(%Event{raw: %{}, type: env.event_type}, env))

  defp refs(%Event{} = event, env), do: refs_from_data(feishu_data(event, env))

  defp refs_from_data(data) do
    id = data["event_id"] || data["message_id"] || "unknown"
    [Map.merge(%{"kind" => "feishu", "id" => id}, data)]
  end

  defp reply_channel(%Config{} = config, env) do
    %{
      adapter: :feishu,
      channel_id: config.channel_id,
      scope_id: env.chat_id,
      thread_id: Map.get(env, :thread_id)
    }
  end

  defp source(%Config{channel_id: channel_id}), do: "bullx://gateway/feishu/#{channel_id}"

  defp reaction_emoji(raw_event) do
    reaction = Map.get(raw_event, "reaction") || raw_event

    Map.get(reaction, "emoji_type") || Map.get(reaction, "emoji") ||
      Map.get(reaction, "reaction_type")
  end

  defp action_id(%CardAction{action: %{"tag" => tag}}) when is_binary(tag), do: tag
  defp action_id(%CardAction{action: %{"name" => name}}) when is_binary(name), do: name

  defp action_id(%CardAction{action: %{"value" => %{"action_id" => id}}}) when is_binary(id),
    do: id

  defp action_id(_), do: "submit"

  defp action_values(%CardAction{action: %{"value" => values}}) when is_map(values), do: values

  defp action_values(%CardAction{action: action}) when is_map(action),
    do: Map.get(action, "value", %{})

  defp action_values(_), do: %{}

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_phone(map, nil), do: map

  defp maybe_put_phone(map, phone) do
    phone
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case BullX.Ext.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        _ -> nil
      end
    end)
    |> case do
      nil -> map
      normalized -> Map.put(map, "phone", normalized)
    end
  end

  defp phone_candidates(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    if String.length(digits) == 11 and String.starts_with?(digits, "1") do
      [trimmed, "+86" <> digits]
    else
      [trimmed]
    end
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp present?(value), do: is_binary(value) and value != ""
  defp now_ms, do: System.system_time(:millisecond)
end
