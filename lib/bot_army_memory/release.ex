defmodule BotArmyMemory.Release do
  @moduledoc """
  Release management tasks for the Memory bot.
  """

  @doc """
  Creates the database for the Memory bot if it doesn't already exist.
  """
  def create do
    IO.puts("Creating Memory database...")
    db_config = Application.get_env(:bot_army_memory, BotArmyMemory.Repo)
    IO.puts("DB Config: #{inspect(db_config)}")
    
    if db_config == nil do
      IO.puts("Error: DB Config is nil. Application might not be started.")
      :error
    else
      create_db_if_missing(db_config)
      :ok
    end
  end

  defp create_db_if_missing(_db_config) do
    # Database creation is now handled by Salt state using psql directly.
    :ok
  end

  @doc """
  Runs Ecto migrations for the Memory bot.
  """
  def migrate do
    IO.puts("Running Memory migrations...")
    Application.ensure_all_started(:bot_army_memory)
    Ecto.Migrator.run(BotArmyMemory.Repo, :up, all: true)
    IO.puts("Migrations complete.")
    :ok
  end
end
