defmodule BullX.Ext do
  @moduledoc """
  Native extensions backed by Rust NIFs.
  """

  use Rustler, otp_app: :bullx, crate: "bullx_ext"

  def generic_hash(data, salt \\ nil)
  def generic_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  def bs58_hash(data, salt \\ nil)
  def bs58_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  def derive_key(key_seed, sub_key_id, extra_context \\ nil)
  def derive_key(_key_seed, _sub_key_id, _extra_context), do: :erlang.nif_error(:nif_not_loaded)

  def generate_key, do: :erlang.nif_error(:nif_not_loaded)
end
