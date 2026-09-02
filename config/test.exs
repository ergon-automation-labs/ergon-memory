import Config

# Test database for store tests. Hermetic-by-default philosophy: tests never
# touch the live ergon_memory database — run `make setup-db` first
# (creates + migrates ergon_memory_test).
# Port 35432 is the local test Postgres (same as synapse's test config);
# port 30006 is the pgbouncer-fronted live endpoint and won't route to
# ad-hoc test databases.
config :bot_army_memory, BotArmyMemory.Repo,
  hostname: System.get_env("BOT_ARMY_MEMORY_DB_HOST", "localhost"),
  port: System.get_env("BOT_ARMY_MEMORY_DB_PORT", "35432") |> String.to_integer(),
  username: System.get_env("BOT_ARMY_MEMORY_DB_USER", "postgres"),
  password: System.get_env("BOT_ARMY_MEMORY_DB_PASSWORD", "postgres"),
  database: System.get_env("BOT_ARMY_MEMORY_DB_TEST_NAME", "ergon_memory_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 500,
  queue_interval: 5000,
  log: false