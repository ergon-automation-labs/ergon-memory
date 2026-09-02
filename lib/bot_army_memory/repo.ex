defmodule BotArmyMemory.Repo do
  use Ecto.Repo,
    otp_app: :bot_army_memory,
    adapter: Ecto.Adapters.Postgres
end
