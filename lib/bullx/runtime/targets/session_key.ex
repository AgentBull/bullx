defmodule BullX.Runtime.Targets.SessionKey do
  @moduledoc false

  alias Jido.Signal

  @default_thread "__default_thread__"

  @type t :: {String.t(), String.t(), String.t(), String.t(), String.t()}

  @spec from_signal(String.t(), Signal.t()) :: {:ok, t()} | {:error, term()}
  def from_signal(target_key, %Signal{} = signal) when is_binary(target_key) do
    with {:ok, adapter} <- fetch_extension(signal, "bullx_channel_adapter"),
         {:ok, channel_id} <- fetch_extension(signal, "bullx_channel_id"),
         {:ok, scope_id} <- fetch_data(signal, "scope_id") do
      thread_id = signal |> data("thread_id") |> default_thread()
      {:ok, {target_key, adapter, channel_id, scope_id, thread_id}}
    end
  end

  @spec default_thread() :: String.t()
  def default_thread, do: @default_thread

  defp fetch_extension(%Signal{} = signal, key) do
    case get_in(signal.extensions || %{}, [key]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_signal_extension, key}}
    end
  end

  defp fetch_data(%Signal{} = signal, key) do
    case data(signal, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_signal_data, key}}
    end
  end

  defp data(%Signal{data: data}, key) when is_map(data), do: Map.get(data, key)
  defp data(_signal, _key), do: nil

  defp default_thread(nil), do: @default_thread
  defp default_thread(""), do: @default_thread
  defp default_thread(thread_id) when is_binary(thread_id), do: thread_id
end
