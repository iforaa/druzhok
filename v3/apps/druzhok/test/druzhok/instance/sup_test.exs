defmodule Druzhok.Instance.SupTest do
  use ExUnit.Case, async: false

  setup do
    name = "test-sup-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_sup_test_#{name}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "You are a test bot.")

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    config = %{
      name: name,
      token: "fake-token-#{name}",
      model: "test-model",
      workspace: workspace,
      api_url: "http://localhost:9999",
      api_key: "fake-key",
      heartbeat_interval: 0,
    }

    %{config: config, name: name}
  end

  test "starts all 3 children and registers them", %{config: config, name: name} do
    {:ok, sup_pid} = Druzhok.Instance.Sup.start_link(config)
    Process.sleep(200)

    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :session})
    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})
    assert [{^sup_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :sup})

    Supervisor.stop(sup_pid)
  end
end
