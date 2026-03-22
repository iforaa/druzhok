defmodule Druzhok.SupervisionTest do
  use ExUnit.Case, async: false

  setup do
    name = "sup-test-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_suptest_#{name}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "You are a test bot.")

    on_exit(fn ->
      Druzhok.InstanceManager.stop(name)
      File.rm_rf!(workspace)
    end)

    {:ok, _} = Druzhok.InstanceManager.create(name, %{
      workspace: workspace, model: "test-model",
      api_url: "http://localhost:9999", api_key: "fake",
      telegram_token: "fake-token-#{name}",
    })

    Process.sleep(300)
    %{name: name}
  end

  test "telegram crash doesn't affect session", %{name: name} do
    [{tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    [{sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})

    Process.exit(tg_pid, :kill)
    Process.sleep(200)

    assert Process.alive?(sess_pid)
    [{new_tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    assert new_tg_pid != tg_pid
  end

  test "session crash doesn't affect telegram", %{name: name} do
    [{tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    [{sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})

    Process.exit(sess_pid, :kill)
    Process.sleep(200)

    assert Process.alive?(tg_pid)
    [{new_sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})
    assert new_sess_pid != sess_pid
  end

  test "scheduler crash doesn't affect telegram or session", %{name: name} do
    [{tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    [{sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})
    [{sched_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})

    Process.exit(sched_pid, :kill)
    Process.sleep(200)

    assert Process.alive?(tg_pid)
    assert Process.alive?(sess_pid)
    [{new_sched_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})
    assert new_sched_pid != sched_pid
  end

  test "create is idempotent", %{name: name} do
    result = Druzhok.InstanceManager.create(name, %{
      workspace: "/tmp/whatever", model: "test",
      api_url: "http://localhost:9999", api_key: "fake",
      telegram_token: "fake",
    })
    assert {:ok, _} = result
  end

  test "stop terminates all processes", %{name: name} do
    Druzhok.InstanceManager.stop(name)
    Process.sleep(200)

    assert Registry.lookup(Druzhok.Registry, {name, :telegram}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :session}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :scheduler}) == []
  end

  test "max restarts stops instance" do
    name = "crashtest-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_crashtest_#{name}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "test")

    {:ok, _} = Druzhok.InstanceManager.create(name, %{
      workspace: workspace, model: "test",
      api_url: "http://localhost:9999", api_key: "fake",
      telegram_token: "fake-#{name}",
    })
    Process.sleep(300)

    for _ <- 1..4 do
      case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
        [{pid, _}] -> Process.exit(pid, :kill)
        [] -> :ok
      end
      Process.sleep(200)
    end

    Process.sleep(1000)

    assert Registry.lookup(Druzhok.Registry, {name, :telegram}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :session}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :sup}) == []

    File.rm_rf!(workspace)
  end
end
