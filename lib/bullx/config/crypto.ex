defmodule BullX.Config.Crypto do
  @moduledoc """
  Per-key encryption for secret `app_configs` rows.

  Encryption key is derived from `BULLX_SECRET_BASE` and the config key, so
  the ciphertext is bound to the specific row and cannot be reused for another
  key.
  """

  @sub_key_prefix "app_configs/"

  @spec encrypt(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def encrypt(plaintext, config_key) when is_binary(plaintext) and is_binary(config_key) do
    with {:ok, key} <- derive_key(config_key) do
      case BullX.Ext.aead_encrypt(plaintext, key) do
        ciphertext when is_binary(ciphertext) -> {:ok, ciphertext}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec decrypt(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(ciphertext, config_key) when is_binary(ciphertext) and is_binary(config_key) do
    with {:ok, key} <- derive_key(config_key) do
      case BullX.Ext.aead_decrypt(ciphertext, key) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        {:error, _reason} = error -> error
      end
    end
  end

  defp derive_key(config_key) do
    case BullX.Ext.derive_key(
           BullX.Config.Secrets.secret_base!(),
           @sub_key_prefix <> config_key,
           "value"
         ) do
      hex when is_binary(hex) -> {:ok, hex}
      {:error, _reason} = error -> error
    end
  end
end
