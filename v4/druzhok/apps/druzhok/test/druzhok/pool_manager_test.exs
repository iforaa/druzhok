defmodule Druzhok.PoolManagerTest do
  use ExUnit.Case, async: false

  alias Druzhok.{Pool, PoolConfig, Repo, Instance}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    :ok
  end

  describe "Pool schema queries" do
    test "next_port returns 18800 when no pools exist" do
      assert Pool.next_port() == 18800
    end

    test "next_port increments from max existing port" do
      Repo.insert!(%Pool{name: "pool-1", container: "c1", port: 18800, status: "running"})
      assert Pool.next_port() == 18801
    end

    test "next_name generates sequential names" do
      assert Pool.next_name() == "openclaw-pool-1"
      Repo.insert!(%Pool{name: "pool-1", container: "c1", port: 18800, status: "running"})
      assert Pool.next_name() == "openclaw-pool-2"
    end

    test "pool_with_capacity finds pool with room" do
      pool = Repo.insert!(%Pool{name: "pool-1", container: "c1", port: 18800, max_tenants: 10, status: "running"})
      found = Pool.pool_with_capacity()
      assert found.id == pool.id
    end

    test "pool_with_capacity returns nil when all pools full" do
      pool = Repo.insert!(%Pool{name: "pool-1", container: "c1", port: 18800, max_tenants: 1, status: "running"})
      # Insert an instance linked to this pool
      Repo.insert!(%Instance{
        name: "test-inst",
        model: "gpt-4o",
        workspace: "/tmp/test",
        tenant_key: "dk-test-123",
        pool_id: pool.id
      })
      assert Pool.pool_with_capacity() == nil
    end

    test "active_pools returns only running/starting pools" do
      Repo.insert!(%Pool{name: "pool-1", container: "c1", port: 18800, status: "running"})
      Repo.insert!(%Pool{name: "pool-2", container: "c2", port: 18801, status: "stopped"})
      pools = Pool.active_pools()
      assert length(pools) == 1
      assert hd(pools).name == "pool-1"
    end
  end

  describe "PoolConfig integration" do
    test "generates valid JSON config from instance-like maps" do
      instances = [
        %{name: "alice", model: "gpt-4o", on_demand_model: nil, tenant_key: "dk-alice", telegram_token: "111:AAA", workspace: "/tmp/alice"},
        %{name: "bob", model: "claude-sonnet", on_demand_model: "claude-opus", tenant_key: "dk-bob", telegram_token: "222:BBB", workspace: "/tmp/bob"}
      ]

      config = PoolConfig.build(instances, port: 18800)
      json = Jason.encode!(config)
      decoded = Jason.decode!(json)

      assert decoded["gateway"]["port"] == 18800
      assert length(decoded["agents"]["list"]) == 2
      assert length(decoded["bindings"]) == 2
      assert map_size(decoded["channels"]["telegram"]["accounts"]) == 2
    end
  end
end
