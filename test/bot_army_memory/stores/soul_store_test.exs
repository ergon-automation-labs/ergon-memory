defmodule BotArmyMemory.Stores.SoulStoreTest do
  use ExUnit.Case, async: true
  @moduletag :stores

  alias BotArmyLibraryRuntime.Tenant
  alias BotArmyMemory.Stores.SoulStore

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BotArmyMemory.Repo)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.checkin(BotArmyMemory.Repo) end)

    suffix = System.unique_integer([:positive])
    {:ok, bot_id: "test_bot_#{suffix}", tenant_id: Tenant.default_tenant_id()}
  end

  describe "get/2" do
    test "returns nil for a bot with no soul", %{bot_id: bot_id, tenant_id: tenant_id} do
      assert SoulStore.get(bot_id, tenant_id) == nil
    end
  end

  describe "upsert/3" do
    test "inserts version 1 and get returns its config", %{bot_id: bot_id, tenant_id: tenant_id} do
      config = %{"identity" => %{"name" => "Test Bot"}, "tone" => "dry"}

      assert {:ok, soul} = SoulStore.upsert(bot_id, config, tenant_id)
      assert soul.version == 1
      assert soul.active == true

      fetched = SoulStore.get(bot_id, tenant_id)
      assert fetched["config"]["identity"]["name"] == "Test Bot"
      assert fetched["config"]["tone"] == "dry"
    end

    test "second upsert bumps the version counter on the same row", %{
      bot_id: bot_id,
      tenant_id: tenant_id
    } do
      {:ok, v1} = SoulStore.upsert(bot_id, %{"identity" => %{"name" => "v1"}}, tenant_id)
      assert v1.version == 1

      {:ok, v2} = SoulStore.upsert(bot_id, %{"identity" => %{"name" => "v2"}}, tenant_id)
      assert v2.version == 2
      assert v2.id == v1.id

      fetched = SoulStore.get(bot_id, tenant_id)
      assert fetched["config"]["identity"]["name"] == "v2"
      assert fetched["version"] == 2
      assert fetched["active"] == true
    end

    test "rejects a config without an identity field", %{bot_id: bot_id, tenant_id: tenant_id} do
      assert {:error, _changeset} = SoulStore.upsert(bot_id, %{"tone" => "no identity"}, tenant_id)
      # Nothing was written
      assert SoulStore.get(bot_id, tenant_id) == nil
    end
  end
end