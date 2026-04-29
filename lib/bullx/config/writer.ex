defmodule BullX.Config.Writer do
  import Ecto.Query

  @req_llm_prefix "bullx.req_llm."

  @doc "Upserts a raw string value into `app_configs` and refreshes ETS."
  def put(key, value) when is_binary(key) and is_binary(value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      BullX.Repo.insert(
        %BullX.Config.AppConfig{key: key, value: value},
        on_conflict: [set: [value: value, updated_at: now]],
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

  @doc "Deletes a key from `app_configs` and refreshes ETS."
  def delete(key) when is_binary(key) do
    BullX.Repo.delete_all(from c in BullX.Config.AppConfig, where: c.key == ^key)
    BullX.Config.Cache.refresh(key)
    sync_req_llm_key!(key)
  end

  defp sync_req_llm_key!(key) do
    case String.starts_with?(key, @req_llm_prefix) do
      true -> BullX.Config.ReqLLM.Bridge.sync_key!(key)
      false -> :ok
    end
  end
end
