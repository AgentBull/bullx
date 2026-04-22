defmodule BullXGateway.SignalContext do
  @moduledoc """
  Policy-facing projection of a canonical inbound signal.

  `BullXGateway.Gating` modules should read this struct instead of reaching
  into raw `Jido.Signal` maps. It keeps the policy surface stable: channel,
  scope, duplex, actor, content, refs, and the parsed semantic event type are
  extracted once from the carrier signal and then reused by gating code.
  """

  alias Jido.Signal

  @type event_type ::
          :message
          | :message_edited
          | :message_recalled
          | :reaction
          | :action
          | :slash_command
          | :trigger

  @type t :: %__MODULE__{
          signal_type: String.t(),
          event_type: event_type(),
          event_name: String.t(),
          event_version: integer(),
          event_data: map(),
          channel: {atom(), String.t()},
          scope_id: String.t(),
          thread_id: String.t() | nil,
          actor: map(),
          duplex: boolean(),
          content: [map()],
          refs: [map()],
          signal: Signal.t()
        }

  defstruct [
    :signal_type,
    :event_type,
    :event_name,
    :event_version,
    :event_data,
    :channel,
    :scope_id,
    :thread_id,
    :actor,
    :duplex,
    :content,
    :refs,
    :signal
  ]

  def from_signal(%Signal{} = signal) do
    with {:ok, event_type} <- event_type(get_in(signal.data, ["event", "type"])),
         {:ok, channel} <- channel(signal.extensions) do
      {:ok,
       %__MODULE__{
         signal_type: signal.type,
         event_type: event_type,
         event_name: get_in(signal.data, ["event", "name"]),
         event_version: get_in(signal.data, ["event", "version"]),
         event_data: get_in(signal.data, ["event", "data"]) || %{},
         channel: channel,
         scope_id: signal.data["scope_id"],
         thread_id: signal.data["thread_id"],
         actor: signal.data["actor"],
         duplex: signal.data["duplex"],
         content: signal.data["content"] || [],
         refs: signal.data["refs"] || [],
         signal: signal
       }}
    end
  end

  defp event_type("message"), do: {:ok, :message}
  defp event_type("message_edited"), do: {:ok, :message_edited}
  defp event_type("message_recalled"), do: {:ok, :message_recalled}
  defp event_type("reaction"), do: {:ok, :reaction}
  defp event_type("action"), do: {:ok, :action}
  defp event_type("slash_command"), do: {:ok, :slash_command}
  defp event_type("trigger"), do: {:ok, :trigger}
  defp event_type(other), do: {:error, {:invalid_event_type, other}}

  defp channel(%{"bullx_channel_adapter" => adapter, "bullx_channel_tenant" => tenant})
       when is_binary(tenant) do
    with {:ok, adapter_atom} <- adapter_atom(adapter) do
      {:ok, {adapter_atom, tenant}}
    end
  end

  defp channel(_), do: {:error, :invalid_channel}

  defp adapter_atom(adapter) when is_atom(adapter), do: {:ok, adapter}

  defp adapter_atom(adapter) when is_binary(adapter) do
    try do
      {:ok, String.to_existing_atom(adapter)}
    rescue
      ArgumentError -> {:error, :invalid_channel}
    end
  end

  defp adapter_atom(_adapter), do: {:error, :invalid_channel}
end
