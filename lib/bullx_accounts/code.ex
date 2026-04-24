defmodule BullXAccounts.Code do
  @moduledoc false

  require Logger

  @activation_code_length 20
  @web_auth_code_length 10
  @alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @alphabet_size byte_size(@alphabet)

  if rem(256, @alphabet_size) != 0 do
    raise "BullXAccounts.Code alphabet size must divide 256 so each byte maps uniformly"
  end

  def activation_code, do: random_code(@activation_code_length)
  def web_auth_code, do: random_code(@web_auth_code_length)

  def hash(plaintext) when is_binary(plaintext) do
    case BullX.Ext.argon2_hash(plaintext) do
      hash when is_binary(hash) -> {:ok, hash}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(plaintext, hash) when is_binary(plaintext) and is_binary(hash) do
    case BullX.Ext.argon2_verify(plaintext, hash) do
      result when is_boolean(result) -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def verified?(plaintext, hash) do
    case verify(plaintext, hash) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.debug("failed to verify BullXAccounts code hash: #{inspect(reason)}")
        false
    end
  end

  defp random_code(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(&binary_part(@alphabet, rem(&1, @alphabet_size), 1))
    |> IO.iodata_to_binary()
  end
end
