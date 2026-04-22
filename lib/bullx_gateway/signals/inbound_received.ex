defmodule BullXGateway.Signals.InboundReceived do
  @moduledoc false

  alias BullXGateway.Inputs
  alias BullXGateway.Json
  alias Jido.Signal

  @type input ::
          BullXGateway.Inputs.Message.t()
          | BullXGateway.Inputs.MessageEdited.t()
          | BullXGateway.Inputs.MessageRecalled.t()
          | BullXGateway.Inputs.Reaction.t()
          | BullXGateway.Inputs.Action.t()
          | BullXGateway.Inputs.SlashCommand.t()
          | BullXGateway.Inputs.Trigger.t()

  @type t :: Signal.t()

  @signal_type "com.agentbull.x.inbound.received"
  @event_categories ~w(message message_edited message_recalled reaction action slash_command trigger)
  @content_kinds ~w(text image audio video file card)

  @spec new(input()) :: {:ok, Signal.t()} | {:error, term()}
  def new(input) do
    with {:ok, attrs} <- signal_attrs(input),
         {:ok, signal} <- Signal.new(attrs),
         {:ok, validated_signal} <- validate_signal(signal) do
      {:ok, validated_signal}
    end
  end

  @spec new!(input()) :: Signal.t()
  def new!(input) do
    case new(input) do
      {:ok, signal} -> signal
      {:error, reason} -> raise ArgumentError, "invalid inbound input: #{inspect(reason)}"
    end
  end

  @spec validate_signal(Signal.t()) :: {:ok, Signal.t()} | {:error, term()}
  def validate_signal(%Signal{} = signal) do
    with :ok <- validate_top_level(signal),
         :ok <- validate_extensions(signal.extensions || %{}),
         :ok <- validate_data(signal.data || %{}) do
      {:ok, signal}
    end
  end

  defp signal_attrs(input) do
    with {:ok, {adapter, tenant}} <- channel(input.channel),
         {:ok, data} <- render_data(input),
         {:ok, extensions} <-
           Json.normalize(%{
             bullx_channel_adapter: adapter,
             bullx_channel_tenant: tenant
           }) do
      {:ok,
       %{
         id: input.id,
         source: input.source,
         type: @signal_type,
         subject: render_subject(input.subject, adapter, input.scope_id, input.thread_id),
         time: render_time(input.time),
         datacontenttype: "application/json",
         data: data,
         extensions: extensions
       }}
    end
  end

  defp render_data(input) do
    with {:ok, actor} <- Json.normalize(input.actor),
         {:ok, adapter_event} <- Json.normalize(input.adapter_event),
         {:ok, refs} <- Json.normalize(Map.get(input, :refs, []) || []),
         {:ok, content} <- render_content(input),
         {:ok, thread_id} <- Json.normalize(input.thread_id) do
      base =
        %{
          "agent_text" => agent_text(input),
          "content" => content,
          "event_category" => event_category(input),
          "duplex" => duplex?(input),
          "adapter_event" => adapter_event,
          "actor" => actor,
          "refs" => refs,
          "scope_id" => input.scope_id,
          "thread_id" => thread_id
        }

      base =
        if duplex?(input) do
          Map.put(base, "reply_channel", normalize_reply_channel(input.reply_channel))
        else
          Map.put(base, "reply_channel", nil)
        end

      category_fields(input, base)
    end
  end

  defp render_content(%Inputs.Message{content: content}), do: normalize_content(content)
  defp render_content(%Inputs.MessageEdited{content: content}), do: normalize_content(content)
  defp render_content(%Inputs.SlashCommand{content: content}), do: normalize_content(content)
  defp render_content(%Inputs.Trigger{content: content}), do: normalize_content(content)
  defp render_content(_input), do: {:ok, []}

  defp normalize_content(content) when is_list(content) do
    case Enum.reduce_while(content, {:ok, []}, fn block, {:ok, acc} ->
           with {:ok, normalized_block} <- Json.normalize(block) do
             {:cont, {:ok, [normalized_block | acc]}}
           else
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp normalize_reply_channel(reply_channel) do
    case Json.normalize(reply_channel || %{}) do
      {:ok, normalized} -> normalized
      {:error, _} -> %{}
    end
  end

  defp category_fields(%Inputs.Message{} = input, base) do
    with {:ok, mentions} <- Json.normalize(input.mentions),
         {:ok, reply_to_external_id} <- Json.normalize(input.reply_to_external_id) do
      {:ok,
       base
       |> maybe_put("mentions", mentions)
       |> Map.put("reply_to_external_id", reply_to_external_id)}
    end
  end

  defp category_fields(%Inputs.MessageEdited{} = input, base) do
    with {:ok, target_external_message_id} <- Json.normalize(input.target_external_message_id),
         {:ok, edited_at} <- Json.normalize(input.edited_at) do
      {:ok,
       base
       |> Map.put("target_external_message_id", target_external_message_id)
       |> Map.put("edited_at", edited_at)}
    end
  end

  defp category_fields(%Inputs.MessageRecalled{} = input, base) do
    with {:ok, target_external_message_id} <- Json.normalize(input.target_external_message_id),
         {:ok, recalled_at} <- Json.normalize(input.recalled_at),
         {:ok, recalled_by_actor} <- Json.normalize(input.recalled_by_actor) do
      {:ok,
       base
       |> Map.put("target_external_message_id", target_external_message_id)
       |> Map.put("recalled_at", recalled_at)
       |> maybe_put("recalled_by_actor", recalled_by_actor)}
    end
  end

  defp category_fields(%Inputs.Reaction{} = input, base) do
    with {:ok, target_external_message_id} <- Json.normalize(input.target_external_message_id),
         {:ok, emoji} <- Json.normalize(input.emoji),
         {:ok, action} <- Json.normalize(input.action) do
      {:ok,
       base
       |> Map.put("target_external_message_id", target_external_message_id)
       |> Map.put("emoji", emoji)
       |> Map.put("action", action)}
    end
  end

  defp category_fields(%Inputs.Action{} = input, base) do
    with {:ok, target_external_message_id} <- Json.normalize(input.target_external_message_id),
         {:ok, action_id} <- Json.normalize(input.action_id),
         {:ok, values} <- Json.normalize(input.values) do
      {:ok,
       base
       |> Map.put("target_external_message_id", target_external_message_id)
       |> Map.put("action_id", action_id)
       |> Map.put("values", values)}
    end
  end

  defp category_fields(%Inputs.SlashCommand{} = input, base) do
    with {:ok, command_name} <- Json.normalize(input.command_name),
         {:ok, args} <- Json.normalize(input.args),
         {:ok, reply_to_external_id} <- Json.normalize(input.reply_to_external_id) do
      {:ok,
       base
       |> Map.put("command_name", command_name)
       |> Map.put("args", args)
       |> Map.put("reply_to_external_id", reply_to_external_id)}
    end
  end

  defp category_fields(%Inputs.Trigger{}, base), do: {:ok, base}

  defp validate_top_level(%Signal{} = signal) do
    cond do
      signal.type != @signal_type -> {:error, {:invalid_type, signal.type}}
      blank?(signal.source) -> {:error, :missing_source}
      blank?(signal.id) -> {:error, :missing_id}
      blank?(signal.time) -> {:error, :missing_time}
      signal.specversion != "1.0.2" -> {:error, {:invalid_specversion, signal.specversion}}
      true -> :ok
    end
  end

  defp validate_extensions(extensions) do
    cond do
      not Json.string_key_map?(extensions) ->
        {:error, :invalid_extensions}

      blank?(extensions["bullx_channel_adapter"]) ->
        {:error, :missing_channel_adapter}

      blank?(extensions["bullx_channel_tenant"]) ->
        {:error, :missing_channel_tenant}

      Map.has_key?(extensions, "bullx_flags") and not valid_flags?(extensions["bullx_flags"]) ->
        {:error, :invalid_flags}

      Map.has_key?(extensions, "bullx_moderation_modified") and
          not is_boolean(extensions["bullx_moderation_modified"]) ->
        {:error, :invalid_moderation_modified}

      Map.has_key?(extensions, "bullx_security") and
          not Json.string_key_map?(extensions["bullx_security"]) ->
        {:error, :invalid_security_metadata}

      true ->
        :ok
    end
  end

  defp validate_data(data) do
    with true <- Json.string_key_map?(data) || {:error, :invalid_data},
         :ok <- validate_event_category(data),
         :ok <- validate_agent_text(data),
         :ok <- validate_content(data),
         :ok <- validate_adapter_event(data),
         :ok <- validate_scope_and_thread(data),
         :ok <- validate_actor(data["actor"]),
         :ok <- validate_refs(data["refs"]),
         :ok <- validate_reply_channel(data),
         :ok <- validate_category_specific(data) do
      :ok
    end
  end

  defp validate_event_category(data) do
    event_category = data["event_category"]
    duplex = data["duplex"]

    cond do
      event_category not in @event_categories ->
        {:error, {:invalid_event_category, event_category}}

      not is_boolean(duplex) ->
        {:error, :invalid_duplex}

      duplex != expected_duplex(event_category) ->
        {:error, :inconsistent_duplex}

      true ->
        :ok
    end
  end

  defp validate_agent_text(data) do
    if blank?(data["agent_text"]), do: {:error, :missing_agent_text}, else: :ok
  end

  defp validate_content(%{"content" => content}) when is_list(content) do
    Enum.reduce_while(content, :ok, fn block, _acc ->
      case validate_content_block(block) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_content(_), do: {:error, :invalid_content}

  defp validate_content_block(%{"kind" => kind, "body" => body})
       when kind in @content_kinds and is_map(body) do
    if kind == "text" or present?(body["fallback_text"]) do
      :ok
    else
      {:error, :missing_fallback_text}
    end
  end

  defp validate_content_block(_), do: {:error, :invalid_content_block}

  defp validate_adapter_event(%{
         "adapter_event" => %{"type" => type, "version" => version, "data" => data}
       })
       when is_binary(type) and type != "" and is_integer(version) and is_map(data) do
    :ok
  end

  defp validate_adapter_event(_), do: {:error, :invalid_adapter_event}

  defp validate_scope_and_thread(data) do
    cond do
      blank?(data["scope_id"]) -> {:error, :missing_scope_id}
      not Map.has_key?(data, "thread_id") -> {:error, :missing_thread_id}
      data["thread_id"] != nil and blank?(data["thread_id"]) -> {:error, :invalid_thread_id}
      true -> :ok
    end
  end

  defp validate_actor(%{"id" => id, "display" => display, "bot" => bot} = actor)
       when is_binary(display) and is_boolean(bot) do
    cond do
      blank?(id) -> {:error, :missing_actor_id}
      not Map.has_key?(actor, "app_user_id") -> :ok
      actor["app_user_id"] == nil -> :ok
      is_binary(actor["app_user_id"]) and actor["app_user_id"] != "" -> :ok
      true -> {:error, :invalid_actor_app_user_id}
    end
  end

  defp validate_actor(_), do: {:error, :invalid_actor}

  defp validate_refs(refs) when is_list(refs) do
    Enum.reduce_while(refs, :ok, fn
      %{"kind" => kind, "id" => id} = ref, _acc when is_binary(kind) and is_binary(id) ->
        if Map.get(ref, "url") in [nil] or is_binary(ref["url"]),
          do: {:cont, :ok},
          else: {:halt, {:error, :invalid_ref}}

      _, _acc ->
        {:halt, {:error, :invalid_ref}}
    end)
  end

  defp validate_refs(_), do: {:error, :invalid_refs}

  defp validate_reply_channel(%{
         "duplex" => true,
         "reply_channel" =>
           %{"adapter" => adapter, "tenant" => tenant, "scope_id" => scope_id} = reply_channel,
         "scope_id" => data_scope_id,
         "thread_id" => data_thread_id
       }) do
    cond do
      blank?(adapter) ->
        {:error, :missing_reply_channel_adapter}

      blank?(tenant) ->
        {:error, :missing_reply_channel_tenant}

      blank?(scope_id) ->
        {:error, :missing_reply_channel_scope_id}

      scope_id != data_scope_id ->
        {:error, :mismatched_reply_channel_scope_id}

      Map.get(reply_channel, "thread_id") != data_thread_id ->
        {:error, :mismatched_reply_channel_thread_id}

      true ->
        :ok
    end
  end

  defp validate_reply_channel(%{"duplex" => true}), do: {:error, :missing_reply_channel}
  defp validate_reply_channel(_), do: :ok

  defp validate_category_specific(%{"event_category" => "message"}), do: :ok

  defp validate_category_specific(%{
         "event_category" => "message_edited",
         "target_external_message_id" => target_external_message_id
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" do
    :ok
  end

  defp validate_category_specific(%{"event_category" => "message_edited"}),
    do: {:error, :missing_target_external_message_id}

  defp validate_category_specific(%{
         "event_category" => "message_recalled",
         "target_external_message_id" => target_external_message_id
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" do
    :ok
  end

  defp validate_category_specific(%{"event_category" => "message_recalled"}),
    do: {:error, :missing_target_external_message_id}

  defp validate_category_specific(%{
         "event_category" => "reaction",
         "target_external_message_id" => target_external_message_id,
         "emoji" => emoji,
         "action" => action
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" and
              is_binary(emoji) and emoji != "" and action in ["added", "removed"] do
    :ok
  end

  defp validate_category_specific(%{"event_category" => "reaction"}),
    do: {:error, :invalid_reaction}

  defp validate_category_specific(%{
         "event_category" => "action",
         "target_external_message_id" => target_external_message_id,
         "action_id" => action_id,
         "values" => values
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" and
              is_binary(action_id) and action_id != "" and is_map(values) do
    :ok
  end

  defp validate_category_specific(%{"event_category" => "action"}), do: {:error, :invalid_action}

  defp validate_category_specific(%{
         "event_category" => "slash_command",
         "command_name" => command_name,
         "args" => args
       })
       when is_binary(command_name) and command_name != "" and is_binary(args) do
    :ok
  end

  defp validate_category_specific(%{"event_category" => "slash_command"}),
    do: {:error, :invalid_slash_command}

  defp validate_category_specific(%{"event_category" => "trigger"}), do: :ok

  defp channel({adapter, tenant}) when is_atom(adapter) and is_binary(tenant),
    do: {:ok, {Atom.to_string(adapter), tenant}}

  defp channel(_), do: {:error, :invalid_channel}

  defp render_subject(subject, _adapter, _scope_id, _thread_id) when is_binary(subject),
    do: subject

  defp render_subject(_subject, adapter, scope_id, nil), do: "#{adapter}:#{scope_id}"

  defp render_subject(_subject, adapter, scope_id, thread_id),
    do: "#{adapter}:#{scope_id}:#{thread_id}"

  defp render_time(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp render_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp render_time(time) when is_binary(time), do: time

  defp agent_text(%Inputs.Message{agent_text: agent_text}), do: agent_text
  defp agent_text(%Inputs.MessageEdited{agent_text: agent_text}), do: agent_text

  defp agent_text(%Inputs.MessageRecalled{agent_text: nil} = input),
    do: "#{actor_display(input.actor)} recalled a message"

  defp agent_text(%Inputs.MessageRecalled{agent_text: agent_text}), do: agent_text

  defp agent_text(%Inputs.Reaction{agent_text: nil, action: action, emoji: emoji} = input) do
    case to_string(action) do
      "removed" -> "#{actor_display(input.actor)} removed reaction #{emoji}"
      _ -> "#{actor_display(input.actor)} reacted with #{emoji}"
    end
  end

  defp agent_text(%Inputs.Reaction{agent_text: agent_text}), do: agent_text
  defp agent_text(%Inputs.Trigger{agent_text: agent_text}), do: agent_text
  defp agent_text(%Inputs.Action{action_id: action_id}), do: "Action submitted: #{action_id}"

  defp agent_text(%Inputs.SlashCommand{command_name: command_name, args: args}),
    do: "/#{command_name} #{args}" |> String.trim()

  defp event_category(%Inputs.Message{}), do: "message"
  defp event_category(%Inputs.MessageEdited{}), do: "message_edited"
  defp event_category(%Inputs.MessageRecalled{}), do: "message_recalled"
  defp event_category(%Inputs.Reaction{}), do: "reaction"
  defp event_category(%Inputs.Action{}), do: "action"
  defp event_category(%Inputs.SlashCommand{}), do: "slash_command"
  defp event_category(%Inputs.Trigger{}), do: "trigger"

  defp duplex?(%Inputs.Trigger{}), do: false
  defp duplex?(_), do: true

  defp expected_duplex("trigger"), do: false
  defp expected_duplex(_), do: true

  defp actor_display(%{display: display}) when is_binary(display) and display != "", do: display

  defp actor_display(%{"display" => display}) when is_binary(display) and display != "",
    do: display

  defp actor_display(%{id: id}), do: id
  defp actor_display(%{"id" => id}), do: id

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank?(value), do: value in [nil, ""]
  defp present?(value), do: not blank?(value)

  defp valid_flags?(flags) when is_list(flags) do
    Enum.all?(flags, fn
      %{"stage" => stage, "module" => module, "reason" => reason, "description" => description}
      when is_binary(stage) and is_binary(module) and is_binary(reason) and is_binary(description) ->
        true

      _ ->
        false
    end)
  end

  defp valid_flags?(_), do: false
end
