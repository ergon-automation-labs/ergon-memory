import Config

# Only test config lives here; dev/prod configure everything through
# config/runtime.exs (ConfigLoader-driven). Do not import dev.exs/prod.exs —
# they don't exist in this repo.
if config_env() == :test do
  config :bot_army_memory, ecto_repos: [BotArmyMemory.Repo]
  import_config "test.exs"
end