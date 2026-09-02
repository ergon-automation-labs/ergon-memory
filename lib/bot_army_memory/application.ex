defmodule BotArmyMemory.Application do
  @moduledoc """
  Memory Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Telemetry and BotArmyLibraryRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_pulse_publisher()
      |> maybe_add_workers()

    opts = [strategy: :one_for_one, name: BotArmyMemory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp env do
    System.get_env("MIX_ENV") || "dev"
  end

  defp maybe_add_repo(children) do
    if env() == "test" do
      children
    else
      [{BotArmyMemory.Repo, []} | children]
    end
  end

  defp maybe_add_pulse_publisher(children) do
    if env() == "test" do
      children
    else
      [{BotArmyMemory.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_workers(children) do
    if env() == "test" do
      children
    else
      # The NATS responder: handles soul.get/upsert and memory.* subjects.
      [
        {BotArmyMemory.NATS.Consumer, []}
        | children
      ]
    end
  end
end
