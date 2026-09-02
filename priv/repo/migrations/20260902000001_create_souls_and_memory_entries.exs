defmodule BotArmyMemory.Repo.Migrations.CreateSoulsAndMemoryEntries do
  @moduledoc """
  Centralizes the two shared runtime tables in the memory service's own
  database (ergon_memory):

  - `souls` — bot personality identity configs (owned by soul.get/upsert)
  - `memory_entries` — general session context notes (memory.append/entries)

  Both mirror the shared runtime migrations' shapes exactly, but with
  create_if_not_exists so a database that already ran the runtime
  MigrationRunner (e.g. a shared-DB deployment) doesn't collide.
  """

  use Ecto.Migration

  def change do
    create_if_not_exists table(:souls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_id, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:config, :jsonb, null: false, default: "{}")
      add(:version, :integer, null: false, default: 1)
      add(:active, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:souls, [:bot_id]))
    create_if_not_exists(index(:souls, [:tenant_id]))
    create_if_not_exists(
      index(:souls, [:bot_id, :tenant_id], unique: true, name: :souls_bot_tenant_unique)
    )

    create_if_not_exists table(:memory_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:scope, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:user_id, :string)
      add(:source, :string)
      add(:kind, :string, null: false, default: "thought")
      add(:payload, :jsonb, null: false, default: "{}")
      add(:recorded_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:memory_entries, [:scope]))
    create_if_not_exists(index(:memory_entries, [:tenant_id]))
    create_if_not_exists(index(:memory_entries, [:kind]))

    create_if_not_exists(
      index(:memory_entries, [:scope, :tenant_id, :kind, :recorded_at])
    )
  end
end