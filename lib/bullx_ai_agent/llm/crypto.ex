defmodule BullXAIAgent.LLM.Crypto do
  @moduledoc """
  Per-provider API key encryption for the LLM catalog.

  Keys are derived from `BULLX_SECRET_BASE` and the provider row id, so the
  encrypted value is bound to one durable provider record.
  """

  @sub_key_prefix "llm_providers/"

  @spec derive_provider_key(binary()) :: {:ok, String.t()} | {:error, term()}
  def derive_provider_key(provider_id) when is_binary(provider_id) do
    case BullX.Ext.derive_key(
           BullX.Config.Secrets.secret_base!(),
           @sub_key_prefix <> provider_id,
           "api_key"
         ) do
      hex when is_binary(hex) -> {:ok, hex}
      {:error, _reason} = error -> error
    end
  end

  @spec encrypt_api_key(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def encrypt_api_key(api_key, provider_id)
      when is_binary(api_key) and is_binary(provider_id) do
    with {:ok, key} <- derive_provider_key(provider_id) do
      case BullX.Ext.aead_encrypt(api_key, key) do
        ciphertext when is_binary(ciphertext) -> {:ok, ciphertext}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec decrypt_api_key(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def decrypt_api_key(ciphertext, provider_id)
      when is_binary(ciphertext) and is_binary(provider_id) do
    with {:ok, key} <- derive_provider_key(provider_id) do
      case BullX.Ext.aead_decrypt(ciphertext, key) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        {:error, _reason} = error -> error
      end
    end
  end
end
