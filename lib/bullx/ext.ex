defmodule BullX.Ext do
  @moduledoc """
  Native extensions backed by Rust NIFs.
  """

  use Rustler, otp_app: :bullx, crate: "bullx_ext"

  @type error_reason :: String.t()
  @type result(value) :: value | {:error, error_reason}
  @type salt :: String.t() | nil
  @type extra_context :: String.t() | nil

  @spec generic_hash(binary(), salt()) :: result(String.t())
  def generic_hash(data, salt \\ nil)
  def generic_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  @spec bs58_hash(binary(), salt()) :: result(String.t())
  def bs58_hash(data, salt \\ nil)
  def bs58_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  @spec derive_key(binary(), String.t(), extra_context()) :: result(String.t())
  def derive_key(key_seed, sub_key_id, extra_context \\ nil)
  def derive_key(_key_seed, _sub_key_id, _extra_context), do: :erlang.nif_error(:nif_not_loaded)

  @spec generate_key() :: result(String.t())
  def generate_key, do: :erlang.nif_error(:nif_not_loaded)
end
