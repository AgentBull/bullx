defmodule BullXGateway.Json do
  @moduledoc """
  Normalizes Gateway payloads into JSON-neutral terms.

  Inbound signals, extensions, and policy metadata must end as string-keyed,
  struct-free data that `Jido.Signal` can carry without encoding surprises.
  This module is stricter than "Jason encodable": most structs are rejected,
  time values are projected to ISO8601 strings, and
  `BullXGateway.Delivery.Content` is the one struct shape Gateway intentionally
  unwraps.
  """

  alias BullXGateway.Delivery.Content

  def normalize(term) do
    do_normalize(term)
  end

  def string_key_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and json_neutral?(value) end)
  end

  def string_key_map?(_), do: false

  def json_neutral?(nil), do: true

  def json_neutral?(value)
      when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value), do: true

  def json_neutral?(list) when is_list(list), do: Enum.all?(list, &json_neutral?/1)
  def json_neutral?(map) when is_map(map), do: string_key_map?(map)
  def json_neutral?(_), do: false

  defp do_normalize(nil), do: {:ok, nil}

  defp do_normalize(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp do_normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp do_normalize(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  defp do_normalize(%NaiveDateTime{} = value), do: {:ok, NaiveDateTime.to_iso8601(value)}
  defp do_normalize(%Date{} = value), do: {:ok, Date.to_iso8601(value)}
  defp do_normalize(%Time{} = value), do: {:ok, Time.to_iso8601(value)}

  defp do_normalize(%Content{} = content) do
    content
    |> Map.from_struct()
    |> do_normalize()
  end

  defp do_normalize(%module{}), do: {:error, {:invalid_json_term, module}}

  defp do_normalize(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case do_normalize(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp do_normalize(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, normalized_key} <- normalize_key(key),
           {:ok, normalized_value} <- do_normalize(value) do
        {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp do_normalize(other), do: {:error, {:invalid_json_term, other}}

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(other), do: {:error, {:invalid_json_key, other}}
end
