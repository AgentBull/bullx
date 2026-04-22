defmodule BullXGateway.Delivery.Outcome do
  @moduledoc """
  JSON-neutral result of one outbound delivery.

  An `Outcome` is produced by the Gateway egress runtime and projected onto
  `Jido.Signal.data` via `to_signal_data/1`. The `:failed` status is
  Gateway-owned: adapters MUST NOT return `{:ok, %Outcome{status: :failed}}`
  (RFC 0003 §5.3.1).
  """

  @type success_status :: :sent | :degraded
  @type status :: success_status() | :failed

  @type t :: %__MODULE__{
          delivery_id: String.t(),
          status: status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: map() | nil
        }

  @type adapter_success_t :: %__MODULE__{
          delivery_id: String.t(),
          status: success_status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: nil
        }

  @enforce_keys [:delivery_id, :status]
  defstruct [
    :delivery_id,
    :status,
    external_message_ids: [],
    primary_external_id: nil,
    warnings: [],
    error: nil
  ]

  @doc """
  Build a success outcome from an adapter's return map.

  The map may use atom or string keys; normalizes to the struct with defaults
  filled in. Intended for use by adapters that want a helper; the Gateway
  egress runtime accepts a raw `%__MODULE__{}` directly.
  """
  @spec new_success(String.t(), success_status(), map() | keyword()) :: adapter_success_t()
  def new_success(delivery_id, status, attrs \\ %{})
      when is_binary(delivery_id) and status in [:sent, :degraded] do
    attrs = normalize_input(attrs)

    %__MODULE__{
      delivery_id: delivery_id,
      status: status,
      external_message_ids: Map.get(attrs, :external_message_ids, []),
      primary_external_id: Map.get(attrs, :primary_external_id),
      warnings: Map.get(attrs, :warnings, []),
      error: nil
    }
  end

  @doc """
  Build a terminal failure outcome.
  """
  @spec new_failure(String.t(), map()) :: t()
  def new_failure(delivery_id, error_map) when is_binary(delivery_id) and is_map(error_map) do
    %__MODULE__{
      delivery_id: delivery_id,
      status: :failed,
      external_message_ids: [],
      primary_external_id: nil,
      warnings: [],
      error: stringify_error(error_map)
    }
  end

  @doc """
  Append warnings to an outcome, preserving order (existing first).
  """
  @spec append_warnings(t(), [String.t()]) :: t()
  def append_warnings(%__MODULE__{warnings: existing} = outcome, new_warnings)
      when is_list(new_warnings) do
    %{outcome | warnings: existing ++ new_warnings}
  end

  @doc """
  Project an `Outcome` onto the `Jido.Signal.data` shape: string keys,
  `status` as a string, no atoms in maps.
  """
  @spec to_signal_data(t()) :: map()
  def to_signal_data(%__MODULE__{} = outcome) do
    %{
      "delivery_id" => outcome.delivery_id,
      "status" => Atom.to_string(outcome.status),
      "external_message_ids" => outcome.external_message_ids,
      "primary_external_id" => outcome.primary_external_id,
      "warnings" => outcome.warnings,
      "error" => stringify_error(outcome.error)
    }
  end

  defp stringify_error(nil), do: nil

  defp stringify_error(error) when is_map(error) do
    error
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string_key(key), stringify_value(value))
    end)
  end

  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_error(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp to_string_key(key) when is_binary(key), do: key
  defp to_string_key(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_input(attrs) when is_list(attrs), do: Map.new(attrs)

  defp normalize_input(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("external_message_ids"), do: :external_message_ids
  defp normalize_key("primary_external_id"), do: :primary_external_id
  defp normalize_key("warnings"), do: :warnings
  defp normalize_key(other), do: other
end
