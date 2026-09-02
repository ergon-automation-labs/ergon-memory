defmodule BotArmyMemory.Stores.MemoryEntryStoreTest do
  use ExUnit.Case, async: true
  @moduletag :stores

  alias BotArmyLibraryRuntime.Tenant
  alias BotArmyMemory.Stores.MemoryEntryStore

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BotArmyMemory.Repo)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.checkin(BotArmyMemory.Repo) end)

    suffix = System.unique_integer([:positive])
    scope = "session-test-#{suffix}"
    {:ok, scope: scope, tenant_id: Tenant.default_tenant_id()}
  end

  describe "append/2" do
    test "inserts an entry and list returns it (chronological)", %{
      scope: scope,
      tenant_id: tenant_id
    } do
      assert {:ok, _id} =
               MemoryEntryStore.append(
                 scope: scope,
                 tenant_id: tenant_id,
                 kind: "thought",
                 payload: %{"note" => "first"}
               )

      assert {:ok, entries} = MemoryEntryStore.list(scope, %{"tenant_id" => tenant_id})
      assert length(entries) == 1
      assert hd(entries)["payload"] == %{"note" => "first"}
      assert hd(entries)["kind"] == "thought"
      assert hd(entries)["scope"] == scope
    end

    test "trims the scope down to the newest `limit` entries", %{
      scope: scope,
      tenant_id: tenant_id
    } do
      # Explicit recorded_at: sub-second appends share clock time, so the
      # test pins deterministic ordering instead of relying on the clock.
      for n <- 1..5 do
        {:ok, _} =
          MemoryEntryStore.append(
            scope: scope,
            tenant_id: tenant_id,
            kind: "thought",
            payload: %{"n" => n},
            recorded_at: DateTime.add(~U[2026-09-02 12:00:00Z], n)
          )
      end

      assert {:ok, entries} =
               MemoryEntryStore.list(scope, %{"tenant_id" => tenant_id, "limit" => 3})

      # Newest 3 kept, oldest-first ordering
      assert Enum.map(entries, & &1["payload"]["n"]) == [3, 4, 5]
    end

    test "clear removes scope entries and reports the count", %{
      scope: scope,
      tenant_id: tenant_id
    } do
      {:ok, _} =
        MemoryEntryStore.append(
          scope: scope,
          tenant_id: tenant_id,
          kind: "thought",
          payload: %{"note" => "delete me"}
        )

      assert {:ok, 1} = MemoryEntryStore.clear(scope, %{"tenant_id" => tenant_id})
      assert {:ok, []} = MemoryEntryStore.list(scope, %{"tenant_id" => tenant_id})
    end

    test "list for an unknown scope is empty", %{scope: scope, tenant_id: tenant_id} do
      assert {:ok, []} = MemoryEntryStore.list("never-appended-#{scope}", %{"tenant_id" => tenant_id})
    end
  end
end