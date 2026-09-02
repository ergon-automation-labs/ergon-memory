import Config

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
