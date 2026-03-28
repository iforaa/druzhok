defmodule Druzhok.SupervisionTest do
  use ExUnit.Case, async: false

  setup do
    name = "sup-test-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_suptest_#{name}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "AGENTS.md"), "You are a test bot.")

    on_exit(fn ->
      Druzhok.InstanceManager.stop(name)
      File.rm_rf!(workspace)
    end)

    {:ok, _} = Druzhok.InstanceManager.create(name, %{
      workspace: workspace, model: "test-model",
      telegram_token: "fake-token-#{name}",
    })

    Process.sleep(200)
    %{name: name}
  end

  test "scheduler is registered after create", %{name: name} do
    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})
  end

  test "scheduler crash restarts and re-registers", %{name: name} do
    [{sched_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})

    Process.exit(sched_pid, :kill)
    Process.sleep(200)

    [{new_sched_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})
    assert new_sched_pid != sched_pid
  end

  test "create is idempotent", %{name: name} do
    result = Druzhok.InstanceManager.create(name, %{
      workspace: "/tmp/whatever", model: "test",
      telegram_token: "fake",
    })
    assert {:ok, _} = result
  end

  test "stop terminates all processes", %{name: name} do
    Druzhok.InstanceManager.stop(name)
    Process.sleep(200)

    assert Registry.lookup(Druzhok.Registry, {name, :scheduler}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :sup}) == []
  end
end
