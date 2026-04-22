defmodule BullXGateway.SignalContext do
  @moduledoc false

  alias Jido.Signal

  @type event_category ::
          :message
          | :message_edited
          | :message_recalled
          | :reaction
          | :action
          | :slash_command
          | :trigger

  @type t :: %__MODULE__{
          signal_type: String.t(),
          event_category: event_category(),
          channel: {atom(), String.t()},
          scope_id: String.t(),
          thread_id: String.t() | nil,
          actor: map(),
          duplex: boolean(),
          adapter_event_type: String.t(),
          adapter_event_version: integer(),
          agent_text: String.t() | nil,
          refs: [map()],
          signal: Signal.t()
        }

  defstruct [
    :signal_type,
    :event_category,
    :channel,
    :scope_id,
    :thread_id,
    :actor,
    :duplex,
    :adapter_event_type,
    :adapter_event_version,
    :agent_text,
    :refs,
    :signal
  ]

  def from_signal(%Signal{} = signal) do
    with {:ok, event_category} <- event_category(signal.data["event_category"]),
         {:ok, channel} <- channel(signal.extensions) do
      {:ok,
       %__MODULE__{
         signal_type: signal.type,
         event_category: event_category,
         channel: channel,
         scope_id: signal.data["scope_id"],
         thread_id: signal.data["thread_id"],
         actor: signal.data["actor"],
         duplex: signal.data["duplex"],
         adapter_event_type: get_in(signal.data, ["adapter_event", "type"]),
         adapter_event_version: get_in(signal.data, ["adapter_event", "version"]),
         agent_text: signal.data["agent_text"],
         refs: signal.data["refs"] || [],
         signal: signal
       }}
    end
  end

  defp event_category("message"), do: {:ok, :message}
  defp event_category("message_edited"), do: {:ok, :message_edited}
  defp event_category("message_recalled"), do: {:ok, :message_recalled}
  defp event_category("reaction"), do: {:ok, :reaction}
  defp event_category("action"), do: {:ok, :action}
  defp event_category("slash_command"), do: {:ok, :slash_command}
  defp event_category("trigger"), do: {:ok, :trigger}
  defp event_category(other), do: {:error, {:invalid_event_category, other}}

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
