import Config

# The salt-rendered config file has to be put somewhere before it can be read: the launchd
# wrapper deliberately skips sourcing an Elixir `%{}` file (it is not shell), and
# `ConfigLoader.get/2` reads `:config_data` from this app's env and then `System.get_env/1` —
# so without these two lines every pillar knob in this file is inert and the release quietly
# runs on its compiled defaults. Measured across the fleet 2026-10-24 (gtd 33c845f5): on
# wife_care the file named the 27B for the press and the running VM answered `nil`, so the
# press silently used the 4B. A bot that reads `ConfigLoader` without loading it reads
# nothing. Guarded off `:test` because a test run has no rendered file and no business
# reading the node's credentials.
if config_env() != :test do
  config_data = BotArmyLibraryRuntime.ConfigLoader.load_config()
  Application.put_env(:bot_army_library_runtime, :config_data, config_data)
end

if config_env() != :test do
  nats_host = BotArmyLibraryRuntime.ConfigLoader.get("NATS_HOST", "localhost")
  nats_port = BotArmyLibraryRuntime.ConfigLoader.get("NATS_PORT", "4222") |> String.to_integer()

  config :bot_army_library_runtime, :nats,
    servers: [{nats_host, nats_port}],
    ping_interval: 5000,
    max_reconnect_attempts: 3,
    reconnect_delay_ms: 100
end

if config_env() != :test do
  db_host = BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_MEMORY_DB_HOST", "localhost")
  db_port = BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_MEMORY_DB_PORT", "30006") |> String.to_integer()
  db_user = BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_MEMORY_DB_USER", "postgres")
  db_pass = BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_MEMORY_DB_PASSWORD", "postgres")
  db_name = BotArmyLibraryRuntime.ConfigLoader.get("BOT_ARMY_MEMORY_DB_NAME", "ergon_memory")

  config :bot_army_memory, BotArmyMemory.Repo,
    hostname: db_host,
    port: db_port,
    username: db_user,
    password: db_pass,
    database: db_name,
    pool_size: 10,
    ssl: false
end

config :bot_army_library_runtime, :auto_start_services, true
