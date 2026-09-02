Application.ensure_all_started(:mox)

ExUnit.configure(exclude: [:integration, :load, :nats_live])

ExUnit.start()

# Define Mox mocks for external dependencies
Mox.defmock(HTTPClientMock, for: BotArmyMemory.HTTPClient)

# Start the Repo for store tests (sandboxed, rolled back per test).
# `make setup-db` must have created ergon_memory_test first; when the
# database is unavailable, store tests will fail loudly rather than
# silently passing against nothing.
case BotArmyMemory.Repo.start_link() do
  {:ok, _pid} ->
    Ecto.Adapters.SQL.Sandbox.mode(BotArmyMemory.Repo, :manual)

  _ ->
    :ok
end
