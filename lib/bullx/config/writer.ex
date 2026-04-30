defmodule BullX.Config.Writer do
  import Ecto.Query

  @req_llm_prefix "bullx.req_llm."

  @doc "Upserts a raw string value into `app_configs` as plaintext and refreshes ETS."
  def put(key, value) when is_binary(key) and is_binary(value) do
    do_put(key, value, :plain)
  end

  @doc "Encrypts `value` and upserts it into `app_configs` as a secret, then refreshes ETS."
  def put_secret(key, value) when is_binary(key) and is_binary(value) do
    with {:ok, ciphertext} <- BullX.Config.Crypto.encrypt(value, key) do
      do_put(key, ciphertext, :secret)
    end
  end

  @doc "Deletes a key from `app_configs` and refreshes ETS."
  def delete(key) when is_binary(key) do
    BullX.Repo.delete_all(from c in BullX.Config.AppConfig, where: c.key == ^key)
    BullX.Config.Cache.refresh(key)
    sync_req_llm_key!(key)
  end

  defp do_put(key, stored_value, type) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      BullX.Repo.insert(
        %BullX.Config.AppConfig{key: key, value: stored_value, type: type},
        on_conflict: [set: [value: stored_value, type: type, updated_at: now]],
        conflict_target: :key
      )

    case result do
      {:ok, _} ->
        BullX.Config.Cache.refresh(key)
        sync_req_llm_key!(key)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp sync_req_llm_key!(key) do
    case String.starts_with?(key, @req_llm_prefix) do
      true -> BullX.Config.ReqLLM.Bridge.sync_key!(key)
      false -> :ok
    end
  end
end
