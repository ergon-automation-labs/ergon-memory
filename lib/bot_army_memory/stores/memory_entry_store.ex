defmodule BotArmyMemory.Stores.MemoryEntryStore do
  @moduledoc """
  Storage logic for general memory entries (`memory_entries` table).

  Carried over from the old runtime `Memory.append/2`: an append inserts a
  kind/payload row for a scope, then trims the scope (per tenant + kind)
  down to the newest `limit` rows, so a scope stays a bounded context
  window rather than an ever-growing table.
  """

  alias BotArmyLibraryRuntime.Tenant
  alias BotArmyMemory.Repo

  @doc """
  Inserts an entry and trims its scope. attrs keys (atoms): scope,
  tenant_id, user_id, source, kind, payload. Returns {:ok, id} | {:error, reason}.
  """
  def append(attrs, limit \\ 10) do
    # recorded_at defaults to clock_timestamp() (true per-statement time,
    # μs precision). Callers may pass an explicit :recorded_at DateTime to
    # force deterministic ordering — rapid successive appends can otherwise
    # share a microsecond, making their relative order genuinely arbitrary.
    id_hex = Ecto.UUID.generate()

    {recorded_expr, recorded_params} =
      case attrs[:recorded_at] do
        %DateTime{} = dt -> {"$8", [dt]}
        _ -> {"timezone('UTC', clock_timestamp())", []}
      end

    insert_query = """
    INSERT INTO memory_entries (
      id, scope, tenant_id, user_id, source, kind, payload, recorded_at,
      inserted_at, updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, #{recorded_expr},
            timezone('UTC', now()), timezone('UTC', now()))
    RETURNING id
    """

    params =
      [
        Ecto.UUID.dump!(id_hex),
        attrs[:scope],
        uuid_param(attrs[:tenant_id]),
        attrs[:user_id],
        attrs[:source],
        attrs[:kind] || "thought",
        attrs[:payload] || %{}
      ] ++ recorded_params

    case Repo.query(insert_query, params) do
      {:ok, %Postgrex.Result{rows: [[id_binary]]}} ->
        trim_scope(attrs[:scope], attrs[:tenant_id], attrs[:kind] || "thought", limit)
        {:ok, Ecto.UUID.load!(id_binary)}

      {:ok, _other} ->
        {:error, :insert_returned_no_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns up to `limit` entries for a scope, oldest first (chronological),
  filtered by tenant and kind. Entries are plain maps.
  """
  def list(scope, opts \\ %{}) when is_map(opts) do
    # Appends always stamp a tenant (the consumer defaults it), so reads
    # must default too — tenant_id = NULL would match nothing.
    tenant_id = Map.get(opts, "tenant_id") || Tenant.default_tenant_id()
    kind = Map.get(opts, "kind", "thought")
    limit = Map.get(opts, "limit", 10)

    query = """
    SELECT scope, tenant_id, user_id, source, kind, payload, recorded_at
    FROM (
      SELECT scope, tenant_id, user_id, source, kind, payload, recorded_at
      FROM memory_entries
      WHERE scope = $1
        AND tenant_id = $2::uuid
        AND kind = $3
      ORDER BY recorded_at DESC, id DESC
      LIMIT $4
    ) recent
    ORDER BY recorded_at ASC
    """

    case Repo.query(query, [scope, uuid_param(tenant_id), kind, limit]) do
      {:ok, %Postgrex.Result{columns: cols, rows: rows}} ->
        {:ok, Enum.map(rows, fn row -> row_to_map(cols, row) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes all entries for a scope (optionally filtered by kind).
  Returns {:ok, deleted_count} | {:error, reason}.
  """
  def clear(scope, opts \\ %{}) when is_map(opts) do
    tenant_id = Map.get(opts, "tenant_id") || Tenant.default_tenant_id()
    kind = Map.get(opts, "kind")

    {query, tail_params} =
      if is_binary(kind) and kind != "" do
        {"""
         DELETE FROM memory_entries
         WHERE scope = $1 AND tenant_id = $2::uuid AND kind = $3
         """, [kind]}
      else
        {"""
         DELETE FROM memory_entries
         WHERE scope = $1 AND tenant_id = $2::uuid
         """, []}
      end

    case Repo.query(query, [scope, uuid_param(tenant_id) | tail_params]) do
      {:ok, %Postgrex.Result{num_rows: n}} -> {:ok, n}
      {:error, reason} -> {:error, reason}
    end
  end

  # Raw-SQL params bypass Ecto's binary_id casting: Postgrex wants the
  # 16-byte form for uuid params.
  defp uuid_param(nil), do: nil

  defp uuid_param(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary} -> binary
      :error -> id
    end
  end

  defp trim_scope(scope, tenant_id, kind, limit) when is_integer(limit) and limit > 0 do
    trim_query = """
    DELETE FROM memory_entries
    WHERE id IN (
      SELECT id FROM (
        SELECT id, row_number() OVER (ORDER BY recorded_at DESC, id DESC) AS rn
        FROM memory_entries
        WHERE scope = $1 AND tenant_id = $2::uuid AND kind = $3
      ) ranked
      WHERE rn > $4
    )
    """

    Repo.query(trim_query, [scope, uuid_param(tenant_id), kind, limit])
    :ok
  end

  defp trim_scope(_scope, _tenant_id, _kind, _limit), do: :ok

  defp row_to_map(cols, row) do
    cols
    |> Enum.zip(row)
    |> Enum.into(%{}, fn
      {"recorded_at", %DateTime{} = dt} ->
        {"at", DateTime.to_iso8601(dt)}

      {"recorded_at", %NaiveDateTime{} = dt} ->
        {"at", NaiveDateTime.to_iso8601(dt)}

      {"tenant_id", binary} when is_binary(binary) and byte_size(binary) == 16 ->
        {"tenant_id", Ecto.UUID.load!(binary)}

      {"payload", %DateTime{} = dt} ->
        {"payload", DateTime.to_iso8601(dt)}

      {k, v} ->
        {k, v}
    end)
  end
end
