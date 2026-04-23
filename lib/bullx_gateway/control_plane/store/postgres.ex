defmodule BullXGateway.ControlPlane.Store.Postgres do
  @moduledoc false
  @behaviour BullXGateway.ControlPlane.Store

  import Ecto.Query

  alias BullXGateway.ControlPlane.DeadLetter
  alias BullXGateway.ControlPlane.DedupeSeen
  alias BullX.Repo

  @impl true
  def transaction(fun) when is_function(fun, 1) do
    case Repo.transaction(fn ->
           case fun.(__MODULE__) do
             {:error, reason} -> Repo.rollback(reason)
             other -> other
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_dedupe_seen(attrs) do
    changeset = DedupeSeen.changeset(%DedupeSeen{}, attrs)

    upsert =
      attrs
      |> Map.take([:source, :external_id, :expires_at, :seen_at])
      |> Map.new()

    case Repo.insert(changeset,
           on_conflict: [set: Enum.to_list(upsert)],
           conflict_target: :dedupe_key
         ) do
      {:ok, _record} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def fetch_dedupe_seen(dedupe_key) do
    case Repo.get(DedupeSeen, dedupe_key) do
      nil -> :error
      record -> {:ok, to_map(record)}
    end
  end

  @impl true
  def list_active_dedupe_seen do
    now = DateTime.utc_now()

    query =
      from dedupe_seen in DedupeSeen,
        where: dedupe_seen.expires_at > ^now

    {:ok, Repo.all(query) |> Enum.map(&to_map/1)}
  end

  @impl true
  def delete_expired_dedupe_seen do
    now = DateTime.utc_now()

    {count, _} =
      Repo.delete_all(from dedupe_seen in DedupeSeen, where: dedupe_seen.expires_at <= ^now)

    {:ok, count}
  end

  @impl true
  def put_dead_letter(attrs) do
    attrs = Map.new(attrs)
    dispatch_id = Map.fetch!(attrs, :dispatch_id)

    attrs =
      attrs
      |> Map.put_new_lazy(:dead_lettered_at, &DateTime.utc_now/0)
      |> Map.put_new(:replay_count, 0)

    case Repo.get(DeadLetter, dispatch_id) do
      nil ->
        %DeadLetter{}
        |> DeadLetter.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, _record} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      existing ->
        advance_attrs =
          attrs
          |> Map.take([
            :final_error,
            :attempts_total,
            :attempts_summary,
            :dead_lettered_at,
            :payload
          ])
          |> Map.put(:replay_count, existing.replay_count)

        existing
        |> DeadLetter.changeset(advance_attrs)
        |> Repo.update()
        |> case do
          {:ok, _record} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @impl true
  def fetch_dead_letter(dispatch_id) do
    case Repo.get(DeadLetter, dispatch_id) do
      nil -> :error
      dead_letter -> {:ok, to_map(dead_letter)}
    end
  end

  @impl true
  def list_dead_letters(filters) do
    query =
      DeadLetter
      |> dead_letter_channel_filter(Keyword.get(filters, :channel))
      |> dead_letter_scope_filter(Keyword.get(filters, :scope_id))
      |> dead_letter_time_filter(:since, Keyword.get(filters, :since))
      |> dead_letter_time_filter(:until, Keyword.get(filters, :until))
      |> dead_letter_limit(Keyword.get(filters, :limit))
      |> order_by([d], desc: d.dead_lettered_at)

    {:ok, Repo.all(query) |> Enum.map(&to_map/1)}
  end

  @impl true
  def increment_dead_letter_replay_count(dispatch_id) do
    {count, _} =
      Repo.update_all(
        from(d in DeadLetter, where: d.dispatch_id == ^dispatch_id),
        inc: [replay_count: 1]
      )

    case count do
      0 -> {:error, :not_found}
      _ -> :ok
    end
  end

  @impl true
  def delete_old_dead_letters(%DateTime{} = before) do
    {count, _} =
      Repo.delete_all(from d in DeadLetter, where: d.dead_lettered_at < ^before)

    {:ok, count}
  end

  @doc """
  Delete a dead-letter row outright.
  """
  @spec purge_dead_letter(String.t()) :: :ok | {:error, :not_found}
  def purge_dead_letter(dispatch_id) do
    {count, _} =
      Repo.delete_all(from d in DeadLetter, where: d.dispatch_id == ^dispatch_id)

    case count do
      0 -> {:error, :not_found}
      _ -> :ok
    end
  end

  defp dead_letter_channel_filter(query, nil), do: query

  defp dead_letter_channel_filter(query, {adapter, channel_id}) do
    adapter_string = to_adapter_string(adapter)

    from d in query,
      where: d.channel_adapter == ^adapter_string and d.channel_id == ^channel_id
  end

  defp dead_letter_scope_filter(query, nil), do: query

  defp dead_letter_scope_filter(query, scope_id),
    do: from(d in query, where: d.scope_id == ^scope_id)

  defp dead_letter_time_filter(query, _tag, nil), do: query

  defp dead_letter_time_filter(query, :since, %DateTime{} = since),
    do: from(d in query, where: d.dead_lettered_at >= ^since)

  defp dead_letter_time_filter(query, :until, %DateTime{} = until),
    do: from(d in query, where: d.dead_lettered_at <= ^until)

  defp dead_letter_limit(query, nil), do: query

  defp dead_letter_limit(query, limit) when is_integer(limit) and limit > 0,
    do: from(d in query, limit: ^limit)

  defp dead_letter_limit(query, _), do: query

  defp to_adapter_string(adapter) when is_atom(adapter), do: Atom.to_string(adapter)
  defp to_adapter_string(adapter) when is_binary(adapter), do: adapter

  defp to_map(schema) do
    schema
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end
end
