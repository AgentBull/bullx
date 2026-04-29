defmodule BullXAccounts.Code do
  @moduledoc """
  Plaintext code generation, hashing, and verification for activation and
  web auth codes.

  The alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` deliberately excludes
  `I`, `O`, `0`, `1` so codes are unambiguous when read aloud or transcribed.

  A compile-time assertion enforces that 256 is divisible by the alphabet
  size — without this property, mapping `:crypto.strong_rand_bytes/1` output
  through `rem/2` would bias certain characters. Re-tuning the alphabet
  away from a power-of-two divisor of 256 must use rejection sampling
  instead.

  Hashing goes through the argon2 NIF in `BullX.Ext`. Codes are short-lived,
  but they are still slow-hashed so a leaked DB cannot be brute-forced
  offline at high speed.
  """

  require Logger

  @activation_code_length 8
  @web_auth_code_length 8
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

  @doc """
  Compare `plaintext` against `hash`.

  Returns `{:ok, true | false}` for a well-formed hash, `{:error, reason}`
  if the NIF rejects the hash itself (e.g. malformed encoding).
  """
  def verify(plaintext, hash) when is_binary(plaintext) and is_binary(hash) do
    case BullX.Ext.argon2_verify(plaintext, hash) do
      result when is_boolean(result) -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Boolean form of `verify/2`.

  Verification errors (malformed hashes, NIF unavailable) are logged at
  debug level and treated as `false`. Use this in match-against-many-hashes
  loops where one bad hash should not abort the search.
  """
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
