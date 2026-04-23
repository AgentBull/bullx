defmodule BullXGateway.Signals.InboundReceived do
  @moduledoc """
  Builds and validates Gateway's canonical inbound carrier signal.

  This module is the narrow contract between adapter-owned
  `BullXGateway.Inputs.*` structs and the internal
  `com.agentbull.x.inbound.received` signal. It owns the JSON-neutral
  projection, default synthetic content for non-message events, CloudEvents
  extension layout, and the type-specific validation BullX expects before
  gating, moderation, and bus publish.
  """

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
  @event_types ~w(message message_edited message_recalled reaction action slash_command trigger)
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
    with {:ok, {adapter, channel_id}} <- channel(input.channel),
         {:ok, data} <- render_data(input),
         {:ok, extensions} <-
           Json.normalize(%{
             bullx_channel_adapter: adapter,
             bullx_channel_id: channel_id
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
         {:ok, event} <- normalize_event(input),
         {:ok, refs} <- Json.normalize(Map.get(input, :refs, []) || []),
         {:ok, content} <- render_content(input),
         {:ok, thread_id} <- Json.normalize(input.thread_id) do
      base =
        %{
          "content" => content,
          "event" => event,
          "duplex" => duplex?(input),
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
  defp render_content(%Inputs.Trigger{content: content}), do: normalize_content(content)

  defp render_content(%Inputs.MessageRecalled{content: content} = input),
    do: normalize_content_or_default(content, [text_block(message_recalled_text(input))])

  defp render_content(%Inputs.Reaction{content: content} = input),
    do: normalize_content_or_default(content, [text_block(reaction_text(input))])

  defp render_content(%Inputs.Action{content: content} = input),
    do: normalize_content_or_default(content, [text_block(action_text(input))])

  defp render_content(%Inputs.SlashCommand{content: content} = input),
    do: normalize_content_or_default(content, [text_block(slash_command_text(input))])

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

  defp normalize_content(_content), do: {:error, :invalid_content}

  defp normalize_content_or_default(content, default_content) when content in [nil, []] do
    normalize_content(default_content)
  end

  defp normalize_content_or_default(content, _default_content), do: normalize_content(content)

  defp normalize_event(input) do
    with {:ok, event} <- Json.normalize(Map.get(input, :event)),
         {:ok, event_name} <- fetch_required_string(event, "name"),
         {:ok, event_version} <- fetch_required(event, "version"),
         {:ok, event_data} <- fetch_required_map(event, "data"),
         {:ok, normalized_event} <-
           Json.normalize(%{
             type: event_type(input),
             name: event_name,
             version: event_version,
             data: event_data
           }) do
      {:ok, normalized_event}
    else
      {:error, :missing_required_key} -> {:error, :invalid_event}
      {:error, :invalid_required_value} -> {:error, :invalid_event}
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

      blank?(extensions["bullx_channel_id"]) ->
        {:error, :missing_channel_id}

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
         :ok <- validate_event(data),
         :ok <- validate_content(data),
         :ok <- validate_scope_and_thread(data),
         :ok <- validate_actor(data["actor"]),
         :ok <- validate_refs(data["refs"]),
         :ok <- validate_reply_channel(data),
         :ok <- validate_type_specific(data) do
      :ok
    end
  end

  defp validate_event(%{
         "event" => %{"type" => type, "name" => name, "version" => version, "data" => event_data},
         "duplex" => duplex
       }) do
    cond do
      type not in @event_types ->
        {:error, {:invalid_event_type, type}}

      not is_boolean(duplex) ->
        {:error, :invalid_duplex}

      duplex != expected_duplex(type) ->
        {:error, :inconsistent_duplex}

      not is_binary(name) or name == "" ->
        {:error, :invalid_event}

      not is_integer(version) ->
        {:error, :invalid_event}

      not is_map(event_data) ->
        {:error, :invalid_event}

      true ->
        :ok
    end
  end

  defp validate_event(_), do: {:error, :invalid_event}

  defp validate_content(%{"content" => [_ | _] = content}) do
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

  defp validate_scope_and_thread(data) do
    cond do
      blank?(data["scope_id"]) -> {:error, :missing_scope_id}
      not Map.has_key?(data, "thread_id") -> {:error, :missing_thread_id}
      data["thread_id"] != nil and blank?(data["thread_id"]) -> {:error, :invalid_thread_id}
      true -> :ok
    end
  end

  defp validate_actor(%{"id" => id, "display" => display, "bot" => bot})
       when is_binary(display) and is_boolean(bot) do
    cond do
      blank?(id) -> {:error, :missing_actor_id}
      blank?(display) -> {:error, :missing_actor_display}
      true -> :ok
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
           %{"adapter" => adapter, "channel_id" => channel_id, "scope_id" => scope_id} =
             reply_channel,
         "scope_id" => data_scope_id,
         "thread_id" => data_thread_id
       }) do
    cond do
      blank?(adapter) ->
        {:error, :missing_reply_channel_adapter}

      blank?(channel_id) ->
        {:error, :missing_reply_channel_id}

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

  defp validate_type_specific(%{"event" => %{"type" => "message"}}), do: :ok

  defp validate_type_specific(%{
         "event" => %{"type" => "message_edited"},
         "target_external_message_id" => target_external_message_id
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" do
    :ok
  end

  defp validate_type_specific(%{"event" => %{"type" => "message_edited"}}),
    do: {:error, :missing_target_external_message_id}

  defp validate_type_specific(%{
         "event" => %{"type" => "message_recalled"},
         "target_external_message_id" => target_external_message_id
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" do
    :ok
  end

  defp validate_type_specific(%{"event" => %{"type" => "message_recalled"}}),
    do: {:error, :missing_target_external_message_id}

  defp validate_type_specific(%{
         "event" => %{"type" => "reaction"},
         "target_external_message_id" => target_external_message_id,
         "emoji" => emoji,
         "action" => action
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" and
              is_binary(emoji) and emoji != "" and action in ["added", "removed"] do
    :ok
  end

  defp validate_type_specific(%{"event" => %{"type" => "reaction"}}),
    do: {:error, :invalid_reaction}

  defp validate_type_specific(%{
         "event" => %{"type" => "action"},
         "target_external_message_id" => target_external_message_id,
         "action_id" => action_id,
         "values" => values
       })
       when is_binary(target_external_message_id) and target_external_message_id != "" and
              is_binary(action_id) and action_id != "" and is_map(values) do
    :ok
  end

  defp validate_type_specific(%{"event" => %{"type" => "action"}}), do: {:error, :invalid_action}

  defp validate_type_specific(%{
         "event" => %{"type" => "slash_command"},
         "command_name" => command_name,
         "args" => args
       })
       when is_binary(command_name) and command_name != "" and is_binary(args) do
    :ok
  end

  defp validate_type_specific(%{"event" => %{"type" => "slash_command"}}),
    do: {:error, :invalid_slash_command}

  defp validate_type_specific(%{"event" => %{"type" => "trigger"}}), do: :ok

  defp channel({adapter, channel_id}) when is_atom(adapter) and is_binary(channel_id),
    do: {:ok, {Atom.to_string(adapter), channel_id}}

  defp channel(_), do: {:error, :invalid_channel}

  defp render_subject(subject, _adapter, _scope_id, _thread_id) when is_binary(subject),
    do: subject

  defp render_subject(_subject, adapter, scope_id, nil), do: "#{adapter}:#{scope_id}"

  defp render_subject(_subject, adapter, scope_id, thread_id),
    do: "#{adapter}:#{scope_id}:#{thread_id}"

  defp render_time(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp render_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp render_time(time) when is_binary(time), do: time

  defp message_recalled_text(input) do
    recaller = input.recalled_by_actor || input.actor
    "#{actor_display(recaller)} recalled a message"
  end

  defp reaction_text(%Inputs.Reaction{action: action, emoji: emoji} = input) do
    case to_string(action) do
      "removed" -> "#{actor_display(input.actor)} removed reaction #{emoji}"
      _ -> "#{actor_display(input.actor)} reacted with #{emoji}"
    end
  end

  defp action_text(%Inputs.Action{action_id: action_id} = input),
    do: "#{actor_display(input.actor)} submitted action: #{action_id}"

  defp slash_command_text(%Inputs.SlashCommand{command_name: command_name, args: args}) do
    ["/", command_name || "", " ", args || ""]
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp event_type(%Inputs.Message{}), do: "message"
  defp event_type(%Inputs.MessageEdited{}), do: "message_edited"
  defp event_type(%Inputs.MessageRecalled{}), do: "message_recalled"
  defp event_type(%Inputs.Reaction{}), do: "reaction"
  defp event_type(%Inputs.Action{}), do: "action"
  defp event_type(%Inputs.SlashCommand{}), do: "slash_command"
  defp event_type(%Inputs.Trigger{}), do: "trigger"

  defp duplex?(%Inputs.Trigger{}), do: false
  defp duplex?(_), do: true

  defp expected_duplex("trigger"), do: false
  defp expected_duplex(_), do: true

  defp text_block(text), do: %{"kind" => "text", "body" => %{"text" => text}}

  defp actor_display(%{display: display}) when is_binary(display) and display != "", do: display

  defp actor_display(%{"display" => display}) when is_binary(display) and display != "",
    do: display

  defp actor_display(%{id: id}), do: id
  defp actor_display(%{"id" => id}), do: id

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_required(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_required_key}
    end
  end

  defp fetch_required_string(map, key) when is_map(map) do
    with {:ok, value} <- fetch_required(map, key),
         true <- (is_binary(value) and value != "") || {:error, :invalid_required_value} do
      {:ok, value}
    end
  end

  defp fetch_required_map(map, key) when is_map(map) do
    with {:ok, value} <- fetch_required(map, key),
         true <- is_map(value) || {:error, :invalid_required_value} do
      {:ok, value}
    end
  end

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
