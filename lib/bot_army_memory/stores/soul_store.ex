defmodule BotArmyMemory.Stores.SoulStore do
  @moduledoc """
  Storage logic for bot souls (personality identity configs).

  One row per (bot_id, tenant_id) — upserts update in place via
  ON CONFLICT and increment the version counter (old runtime semantics:
  the souls table carries a unique bot+tenant constraint).
  """

  import Ecto.Query
  alias BotArmyMemory.Repo
  alias BotArmyMemory.Schemas.Soul

  @doc """
  Returns the active soul row (as a plain map) for bot_id + tenant_id,
  or nil when the bot has no soul yet.
  """
  def get(bot_id, tenant_id) do
    query =
      from s in Soul,
        where: s.bot_id == ^bot_id and s.tenant_id == ^tenant_id and s.active,
        order_by: [desc: s.version],
        limit: 1

    case Repo.one(query) do
      nil -> nil
      soul -> row_to_map(soul)
    end
  end

  @doc """
  Upserts the soul config for bot_id + tenant_id: ON CONFLICT updates the
  row in place and increments its version. Returns {:ok, soul} | {:error, changeset}.
  """
  def upsert(bot_id, config, tenant_id) do
    %Soul{}
    |> Soul.changeset(%{
      bot_id: bot_id,
      tenant_id: tenant_id,
      config: config,
      version: 1,
      active: true
    })
    |> Repo.insert(
      on_conflict:
        from(s in Soul,
          update: [inc: [version: 1], set: [config: ^config, active: true]]
        ),
      conflict_target: [:bot_id, :tenant_id],
      returning: true
    )
  end

  defp row_to_map(%Soul{} = s) do
    %{
      "bot_id" => s.bot_id,
      "tenant_id" => s.tenant_id,
      "config" => s.config,
      "version" => s.version,
      "active" => s.active
    }
  end
end