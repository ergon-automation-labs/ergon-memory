defmodule BotArmyMemory.Stores.ExchangeStoreTest do
  use ExUnit.Case, async: true
  @moduletag :stores

  alias BotArmyLibraryRuntime.Tenant
  alias BotArmyMemory.Stores.ExchangeStore

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BotArmyMemory.Repo)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.checkin(BotArmyMemory.Repo) end)

    session_id = Ecto.UUID.generate()
    tenant_id = Tenant.default_tenant_id()
    {:ok, session_id: session_id, tenant_id: tenant_id}
  end

  describe "record/1 + list/2" do
    test "records and lists an exchange with map opts", %{session_id: sid, tenant_id: tid} do
      assert {:ok, _exchange} =
               ExchangeStore.record(%{
                 "session_id" => sid,
                 "tenant_id" => tid,
                 "question" => "what next?",
                 "answer" => "ship it",
                 "source" => "test",
                 "meta" => %{}
               })

      # opts are string-keyed maps straight from the NATS JSON body — the
      # Keyword.get crash regression this test pins down
      assert {:ok, [entry]} = ExchangeStore.list(sid, %{"tenant_id" => tid, "limit" => 10})
      assert entry["question"] == "what next?"
      assert entry["answer"] == "ship it"
    end

    test "clear returns the deleted count", %{session_id: sid, tenant_id: tid} do
      {:ok, _} = ExchangeStore.record(%{"session_id" => sid, "tenant_id" => tid,
        "question" => "q", "answer" => "a", "meta" => %{}})

      assert {:ok, 1} = ExchangeStore.clear(sid, %{"tenant_id" => tid})
      assert {:ok, []} = ExchangeStore.list(sid, %{})
    end
  end
end