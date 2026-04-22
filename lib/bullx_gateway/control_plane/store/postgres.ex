defmodule BullXGateway.ControlPlane.Store.Postgres do
  @moduledoc false
  @behaviour BullXGateway.ControlPlane.Store

  import Ecto.Query

  alias BullXGateway.ControlPlane.DedupeSeen
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
  def put_dispatch(_attrs), do: {:error, :not_implemented}

  @impl true
  def update_dispatch(_id, _changes), do: {:error, :not_implemented}

  @impl true
  def delete_dispatch(_id), do: {:error, :not_implemented}

  @impl true
  def fetch_dispatch(_id), do: :error

  @impl true
  def list_dispatches_by_scope(_channel, _scope_id, _statuses), do: {:ok, []}

  @impl true
  def put_attempt(_attrs), do: {:error, :not_implemented}

  @impl true
  def list_attempts(_dispatch_id), do: {:ok, []}

  @impl true
  def put_dead_letter(_attrs), do: {:error, :not_implemented}

  @impl true
  def fetch_dead_letter(_dispatch_id), do: :error

  @impl true
  def list_dead_letters(_filters), do: {:ok, []}

  @impl true
  def increment_dead_letter_replay_count(_dispatch_id), do: {:error, :not_implemented}

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
