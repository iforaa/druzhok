defmodule Druzhok.Instance.SupTest do
  use ExUnit.Case, async: false

  setup do
    name = "test-sup-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_sup_test_#{name}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    config = %{
      name: name,
      model: "test-model",
      workspace: workspace,
      heartbeat_interval: 0,
    }

    %{config: config, name: name}
  end

  test "starts scheduler and registers sup", %{config: config, name: name} do
    {:ok, sup_pid} = Druzhok.Instance.Sup.start_link(config)
    Process.sleep(100)

    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})
    assert [{^sup_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :sup})

    Supervisor.stop(sup_pid)
  end
end
