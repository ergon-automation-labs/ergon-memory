defmodule BotArmyMemory.Stores.ExchangeStore do
  @moduledoc """
  Storage logic for conversation exchanges.
  """

  import Ecto.Query
  alias BotArmyMemory.Repo
  alias BotArmyMemory.Schemas.Exchange

  def record(attrs) do
    %Exchange{}
    |> Exchange.changeset(attrs)
    |> Repo.insert()
  end

  # Opts arrive as a string-keyed map straight from the NATS JSON body —
  # Keyword.get here crashed the consumer on every list request.
  def list(session_id, opts \\ %{}) when is_map(opts) do
    tenant_id = Map.get(opts, "tenant_id")
    limit = Map.get(opts, "limit", 10)

    query =
      from(e in Exchange,
        where: e.session_id == ^session_id
      )

    query = if tenant_id, do: where(query, [e], e.tenant_id == ^tenant_id), else: query

    query
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&schema_to_map/1)
    |> then(&{:ok, &1})
  end

  def clear(session_id, opts \\ %{}) when is_map(opts) do
    tenant_id = Map.get(opts, "tenant_id")

    query =
      from(e in Exchange,
        where: e.session_id == ^session_id
      )

    query = if tenant_id, do: where(query, [e], e.tenant_id == ^tenant_id), else: query

    case Repo.delete_all(query) do
      {count, _} -> {:ok, count}
    end
  end

  defp schema_to_map(%Exchange{} = e) do
    %{
      "question" => e.question,
      "answer" => e.answer,
      "at" => to_iso8601(e.inserted_at),
      "source" => e.source,
      "meta" => e.meta
    }
  end

  # timestamps() defaults to :naive_datetime in this repo — handle both
  # naive and tz-aware forms.
  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
