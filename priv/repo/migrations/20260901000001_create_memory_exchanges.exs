defmodule BotArmyMemory.Repo.Migrations.CreateMemoryExchanges do
  use Ecto.Migration

  def change do
    create table(:memory_exchanges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :binary_id, null: false
      add :tenant_id, :binary_id, null: false
      add :question, :text, null: false
      add :answer, :text, null: false
      add :source, :string
      add :meta, :map, default: "{}"

      timestamps()
    end

    create index(:memory_exchanges, [:session_id])
    create index(:memory_exchanges, [:tenant_id])
  end
end
