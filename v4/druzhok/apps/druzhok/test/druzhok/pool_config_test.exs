defmodule Druzhok.PoolConfigTest do
  use ExUnit.Case, async: true

  alias Druzhok.PoolConfig

  @instance1 %{
    name: "alice",
    model: "meta-llama/llama-3.1-8b-instruct",
    on_demand_model: nil,
    tenant_key: "key-alice",
    telegram_token: "token-alice",
    workspace: "/host/data/alice/workspace"
  }

  @instance2 %{
    name: "bob",
    model: "meta-llama/llama-3.1-70b-instruct",
    on_demand_model: "deepseek-ai/deepseek-r1",
    tenant_key: "key-bob",
    telegram_token: "token-bob",
    workspace: "/host/data/bob/workspace"
  }

  describe "build/2" do
    test "single instance generates correct top-level keys" do
      config = PoolConfig.build([@instance1])
      assert Map.has_key?(config, "gateway")
      assert Map.has_key?(config, "session")
      assert Map.has_key?(config, "models")
      assert Map.has_key?(config, "agents")
      assert Map.has_key?(config, "channels")
      assert Map.has_key?(config, "bindings")
    end

    test "gateway uses default port 18800" do
      config = PoolConfig.build([@instance1])
      assert config["gateway"]["port"] == 18800
      assert config["gateway"]["bind"] == "loopback"
      assert config["gateway"]["reload"]["mode"] == "hybrid"
    end

    test "custom port via opts" do
      config = PoolConfig.build([@instance1], port: 19000)
      assert config["gateway"]["port"] == 19000
    end

    test "session dmScope is per-channel-peer" do
      config = PoolConfig.build([@instance1])
      assert config["session"]["dmScope"] == "per-channel-peer"
    end

    test "single instance generates correct provider" do
      config = PoolConfig.build([@instance1])
      providers = config["models"]["providers"]
      assert Map.has_key?(providers, "tenant-alice")
      provider = providers["tenant-alice"]
      assert provider["apiKey"] == "key-alice"
      assert provider["api"] == "openai-completions"
      assert String.ends_with?(provider["baseUrl"], "/v1")
    end

    test "without on_demand_model, models list has only default entry" do
      config = PoolConfig.build([@instance1])
      models = config["models"]["providers"]["tenant-alice"]["models"]
      assert length(models) == 1
      assert hd(models)["id"] == @instance1.model
      assert hd(models)["name"] == "default"
    end

    test "with on_demand_model, models list includes smart entry" do
      config = PoolConfig.build([@instance2])
      models = config["models"]["providers"]["tenant-bob"]["models"]
      assert length(models) == 2
      names = Enum.map(models, & &1["name"])
      assert "default" in names
      assert "smart" in names
      smart = Enum.find(models, &(&1["name"] == "smart"))
      assert smart["id"] == @instance2.on_demand_model
    end

    test "sandbox mode is 'all' in agent defaults" do
      config = PoolConfig.build([@instance1])
      assert config["agents"]["defaults"]["sandbox"]["mode"] == "off"
    end

    test "single instance agent has correct id and workspace" do
      config = PoolConfig.build([@instance1])
      agents = config["agents"]["list"]
      assert length(agents) == 1
      agent = hd(agents)
      assert agent["id"] == "alice"
      assert agent["workspace"] == "/data/workspaces/alice"
      assert agent["model"] == "tenant-alice/#{@instance1.model}"
    end

    test "workspace path in config is container-relative, not host path" do
      config = PoolConfig.build([@instance1])
      agent = hd(config["agents"]["list"])
      refute String.contains?(agent["workspace"], "/host/")
      assert String.starts_with?(agent["workspace"], "/data/")
    end

    test "telegram accounts keyed by instance name" do
      config = PoolConfig.build([@instance1])
      accounts = config["channels"]["telegram"]["accounts"]
      assert Map.has_key?(accounts, "alice")
      assert accounts["alice"]["botToken"] == "token-alice"
    end

    test "bindings connect agent to telegram account by name" do
      config = PoolConfig.build([@instance1])
      bindings = config["bindings"]
      assert length(bindings) == 1
      binding = hd(bindings)
      assert binding["agentId"] == "alice"
      assert binding["match"]["channel"] == "telegram"
      assert binding["match"]["accountId"] == "alice"
    end

    test "multiple instances generate correct providers, agents, bindings, accounts" do
      config = PoolConfig.build([@instance1, @instance2])

      providers = config["models"]["providers"]
      assert Map.has_key?(providers, "tenant-alice")
      assert Map.has_key?(providers, "tenant-bob")

      agents = config["agents"]["list"]
      agent_ids = Enum.map(agents, & &1["id"])
      assert "alice" in agent_ids
      assert "bob" in agent_ids

      accounts = config["channels"]["telegram"]["accounts"]
      assert Map.has_key?(accounts, "alice")
      assert Map.has_key?(accounts, "bob")

      bindings = config["bindings"]
      assert length(bindings) == 2
      bound_ids = Enum.map(bindings, & &1["agentId"])
      assert "alice" in bound_ids
      assert "bob" in bound_ids
    end

    test "config is JSON-serializable" do
      config = PoolConfig.build([@instance1, @instance2])
      assert {:ok, json} = Jason.encode(config)
      assert is_binary(json)
      assert {:ok, decoded} = Jason.decode(json)
      assert is_map(decoded)
    end
  end
end
