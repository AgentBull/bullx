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

  @spec uuid_shorten(String.t()) :: result(String.t())
  def uuid_shorten(_uuid_v4), do: :erlang.nif_error(:nif_not_loaded)

  @spec gen_uuid() :: String.t()
  def gen_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @spec gen_uuid_v7() :: String.t()
  def gen_uuid_v7, do: :erlang.nif_error(:nif_not_loaded)

  @spec gen_base36_uuid() :: String.t()
  def gen_base36_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @spec short_uuid_expand(String.t()) :: result(String.t())
  def short_uuid_expand(_short_uuid), do: :erlang.nif_error(:nif_not_loaded)

  @spec base58_encode(binary()) :: result(String.t())
  def base58_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec base58_decode(String.t()) :: result(binary())
  def base58_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec base64_url_safe_encode(binary()) :: result(String.t())
  def base64_url_safe_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec base64_url_safe_decode(String.t()) :: result(binary())
  def base64_url_safe_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec any_ascii(String.t()) :: result(String.t())
  def any_ascii(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec z85_encode(binary()) :: result(String.t())
  def z85_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @spec z85_decode(String.t()) :: result(binary())
  def z85_decode(_input), do: :erlang.nif_error(:nif_not_loaded)
end
