defmodule BullXFeishu.Error do
  @moduledoc """
  Maps Feishu SDK/API failures into Gateway adapter error maps.

  Gateway retry, DLQ, and operator recovery logic expects JSON-neutral maps
  with a string `kind`. This module is the single normalization boundary for
  Feishu adapter failures.
  """

  alias FeishuOpenAPI.Error, as: SDKError

  @rate_limit_codes [99_991_400]
  @auth_codes [99_991_663, 99_991_664, 99_991_671, 10_012, 514, 403, 1_000_040_350]
  @reply_missing_codes [230_011, 231_003]

  @spec map(term()) :: map()
  def map(%SDKError{} = error) do
    error
    |> kind()
    |> build(error)
  end

  def map(%{"kind" => kind} = error) when is_binary(kind), do: stringify(error)
  def map({:payload, message}), do: payload(message)
  def map({:unsupported, message}), do: unsupported(message)
  def map({:stream_cancelled, message}), do: base("stream_cancelled", message, %{})
  def map(reason), do: base("unknown", "Feishu adapter error", %{"reason" => inspect(reason)})

  @spec payload(String.t(), map()) :: map()
  def payload(message, details \\ %{}), do: base("payload", message, details)

  @spec unsupported(String.t(), map()) :: map()
  def unsupported(message, details \\ %{}), do: base("unsupported", message, details)

  @spec reply_target_missing?(term()) :: boolean()
  def reply_target_missing?(%SDKError{code: code}), do: code in @reply_missing_codes
  def reply_target_missing?(_), do: false

  defp kind(%SDKError{http_status: 429}), do: "rate_limit"
  defp kind(%SDKError{code: code}) when code in @rate_limit_codes, do: "rate_limit"
  defp kind(%SDKError{http_status: status}) when status in [401, 403], do: "auth"
  defp kind(%SDKError{code: code}) when code in @auth_codes, do: "auth"
  defp kind(%SDKError{code: :transport}), do: "network"
  defp kind(%SDKError{code: :rate_limited}), do: "rate_limit"

  defp kind(%SDKError{code: code}) when code in [:bad_path, :bad_file, :unexpected_shape],
    do: "payload"

  defp kind(%SDKError{}), do: "unknown"

  defp build("rate_limit", %SDKError{} = error) do
    details =
      error
      |> details()
      |> Map.put_new("retry_after_ms", retry_after_ms(error))

    base("rate_limit", "Feishu API rate limited", details)
  end

  defp build("auth", %SDKError{} = error),
    do: base("auth", "Feishu API authentication failed", details(error))

  defp build("network", %SDKError{} = error),
    do: base("network", "Feishu API transport failed", details(error))

  defp build("payload", %SDKError{} = error),
    do: base("payload", error.msg || "Invalid Feishu payload", details(error))

  defp build(kind, %SDKError{} = error),
    do: base(kind, error.msg || "Feishu API error", details(error))

  defp details(%SDKError{} = error) do
    %{}
    |> maybe_put("code", error.code)
    |> maybe_put("http_status", error.http_status)
    |> maybe_put("log_id", error.log_id)
  end

  defp retry_after_ms(%SDKError{details: %{"retry_after" => value}}) when is_integer(value),
    do: value

  defp retry_after_ms(_), do: 1_000

  defp base(kind, message, details) do
    %{
      "kind" => kind,
      "message" => message,
      "details" => stringify(details)
    }
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
