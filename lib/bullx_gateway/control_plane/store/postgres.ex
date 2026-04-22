defmodule BullXGateway.ControlPlane.Store.Postgres do
  @moduledoc false
  @behaviour BullXGateway.ControlPlane.Store

  import Ecto.Query

  alias BullXGateway.ControlPlane.Attempt
  alias BullXGateway.ControlPlane.DeadLetter
  alias BullXGateway.ControlPlane.DedupeSeen
  alias BullXGateway.ControlPlane.Dispatch
  alias BullXGateway.ControlPlane.TriggerRecord
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
  def put_trigger_record(attrs) do
    %TriggerRecord{}
    |> TriggerRecord.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _record} -> :ok
      {:error, changeset} -> changeset_error(changeset, :dedupe_key)
    end
  end

  @impl true
  def fetch_trigger_record_by_dedupe_key(dedupe_key) do
    query =
      from record in TriggerRecord,
        where: record.dedupe_key == ^dedupe_key,
        order_by: [desc: record.inserted_at],
        limit: 1

    case Repo.one(query) do
      nil -> :error
      record -> {:ok, to_map(record)}
    end
  end

  @impl true
  def list_trigger_records(filters \\ []) do
    query =
      TriggerRecord
      |> maybe_filter_published(filters)
      |> maybe_filter_inserted_before(filters)
      |> maybe_limit(filters)

    {:ok, Repo.all(query) |> Enum.map(&to_map/1)}
  end

  @impl true
  def update_trigger_record(id, changes) do
    case Repo.get(TriggerRecord, id) do
      nil ->
        {:error, :not_found}

      record ->
        record
        |> TriggerRecord.update_changeset(changes)
        |> Repo.update()
        |> case do
          {:ok, _record} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
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
  def delete_old_trigger_records(before) do
    {count, _} =
      Repo.delete_all(from record in TriggerRecord, where: record.inserted_at < ^before)

    {:ok, count}
  end

  @impl true
  def put_dispatch(attrs) do
    %Dispatch{}
    |> Dispatch.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _record} ->
        :ok

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :id),
          do: {:error, :duplicate},
          else: {:error, {:changeset, errors}}
    end
  end

  @impl true
  def update_dispatch(id, changes) do
    case Repo.get(Dispatch, id) do
      nil ->
        {:error, :not_found}

      dispatch ->
        dispatch
        |> Dispatch.update_changeset(Map.new(changes))
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, to_map(updated)}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @impl true
  def delete_dispatch(id) do
    {count, _} =
      Repo.delete_all(from dispatch in Dispatch, where: dispatch.id == ^id)

    case count do
      0 -> {:error, :not_found}
      _ -> :ok
    end
  end

  @impl true
  def fetch_dispatch(id) do
    case Repo.get(Dispatch, id) do
      nil -> :error
      dispatch -> {:ok, to_map(dispatch)}
    end
  end

  @impl true
  def list_dispatches_by_scope({adapter, tenant}, scope_id, statuses) do
    adapter_string = to_adapter_string(adapter)
    status_strings = Enum.map(statuses, &to_status_string/1)

    query =
      from dispatch in Dispatch,
        where:
          dispatch.channel_adapter == ^adapter_string and dispatch.channel_tenant == ^tenant and
            dispatch.scope_id == ^scope_id,
        order_by: [asc: dispatch.inserted_at]

    query =
      case status_strings do
        [] -> query
        statuses -> from dispatch in query, where: dispatch.status in ^statuses
      end

    {:ok, Repo.all(query) |> Enum.map(&to_map/1)}
  end

  @impl true
  def put_attempt(attrs) do
    attrs = Map.new(attrs)
    id = Map.fetch!(attrs, :id)

    case Repo.get(Attempt, id) do
      nil ->
        %Attempt{}
        |> Attempt.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, _record} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      existing ->
        existing
        |> Attempt.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, _record} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @impl true
  def list_attempts(dispatch_id) do
    query =
      from attempt in Attempt,
        where: attempt.dispatch_id == ^dispatch_id,
        order_by: [asc: attempt.attempt]

    {:ok, Repo.all(query) |> Enum.map(&to_map/1)}
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
        # Upsert-style on a replay's terminal failure: preserve replay_count,
        # advance attempts_total, refresh final_error and dead_lettered_at.
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
      |> dead_letter_archived_filter(Keyword.get(filters, :include_archived, false))
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

  @doc """
  Delete attempt rows older than `before`.
  """
  @spec delete_old_attempts(DateTime.t()) :: {:ok, non_neg_integer()}
  def delete_old_attempts(%DateTime{} = before) do
    {count, _} =
      Repo.delete_all(from attempt in Attempt, where: attempt.inserted_at < ^before)

    {:ok, count}
  end

  @doc """
  Delete dead-letter rows older than `before` that are not archived.
  """
  @spec delete_old_dead_letters(DateTime.t()) :: {:ok, non_neg_integer()}
  def delete_old_dead_letters(%DateTime{} = before) do
    {count, _} =
      Repo.delete_all(
        from d in DeadLetter,
          where: d.dead_lettered_at < ^before and is_nil(d.archived_at)
      )

    {:ok, count}
  end

  @doc """
  Set `archived_at` on a dead-letter row.
  """
  @spec archive_dead_letter(String.t()) :: :ok | {:error, :not_found}
  def archive_dead_letter(dispatch_id) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(d in DeadLetter, where: d.dispatch_id == ^dispatch_id and is_nil(d.archived_at)),
        set: [archived_at: now]
      )

    case count do
      0 -> {:error, :not_found}
      _ -> :ok
    end
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

  defp dead_letter_channel_filter(query, {adapter, tenant}) do
    adapter_string = to_adapter_string(adapter)

    from d in query,
      where: d.channel_adapter == ^adapter_string and d.channel_tenant == ^tenant
  end

  defp dead_letter_scope_filter(query, nil), do: query

  defp dead_letter_scope_filter(query, scope_id),
    do: from(d in query, where: d.scope_id == ^scope_id)

  defp dead_letter_time_filter(query, _tag, nil), do: query

  defp dead_letter_time_filter(query, :since, %DateTime{} = since),
    do: from(d in query, where: d.dead_lettered_at >= ^since)

  defp dead_letter_time_filter(query, :until, %DateTime{} = until),
    do: from(d in query, where: d.dead_lettered_at <= ^until)

  defp dead_letter_archived_filter(query, true), do: query

  defp dead_letter_archived_filter(query, _),
    do: from(d in query, where: is_nil(d.archived_at))

  defp dead_letter_limit(query, nil), do: query

  defp dead_letter_limit(query, limit) when is_integer(limit) and limit > 0,
    do: from(d in query, limit: ^limit)

  defp dead_letter_limit(query, _), do: query

  defp to_adapter_string(adapter) when is_atom(adapter), do: Atom.to_string(adapter)
  defp to_adapter_string(adapter) when is_binary(adapter), do: adapter

  defp to_status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp to_status_string(status) when is_binary(status), do: status

  defp changeset_error(%Ecto.Changeset{errors: errors} = changeset, field) do
    if Keyword.has_key?(errors, field) do
      {:error, :duplicate}
    else
      {:error, changeset}
    end
  end

  defp maybe_filter_published(query, filters) do
    case Keyword.get(filters, :published) do
      :pending -> from record in query, where: is_nil(record.published_at)
      :published -> from record in query, where: not is_nil(record.published_at)
      _ -> query
    end
  end

  defp maybe_filter_inserted_before(query, filters) do
    case Keyword.get(filters, :inserted_before) do
      %DateTime{} = inserted_before ->
        from record in query, where: record.inserted_at < ^inserted_before

      _ ->
        query
    end
  end

  defp maybe_limit(query, filters) do
    case Keyword.get(filters, :limit) do
      limit when is_integer(limit) and limit > 0 -> from record in query, limit: ^limit
      _ -> query
    end
  end

  defp to_map(schema) do
    schema
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end
end
