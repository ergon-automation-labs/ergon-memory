defmodule BotArmyMemory.Schemas.MemoryEntry do
  @moduledoc """
  Ecto schema for the shared `memory_entries` table (general session
  context notes — kind/payload rows, as opposed to Q/A exchanges).

  The table is created by the shared runtime migration
  (`20260420000003_create_memory_entries`); this service now owns its
  centralized read/write paths.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "memory_entries" do
    field :scope, :string
    field :tenant_id, :binary_id
    field :user_id, :string
    field :source, :string
    field :kind, :string, default: "thought"
    field :payload, :map, default: %{}
    field :recorded_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:scope, :tenant_id, :user_id, :source, :kind, :payload, :recorded_at])
    |> validate_required([:scope, :tenant_id, :kind, :payload, :recorded_at])
  end
end