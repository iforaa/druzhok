defmodule Druzhok.InstanceWatcherTest do
  use ExUnit.Case, async: false

  alias Druzhok.InstanceWatcher

  setup do
    # InstanceWatcher is already started by the application supervision tree
    :ok
  end

  test "receives DOWN when watched process dies" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    InstanceWatcher.watch("test-instance", pid)
    Process.exit(pid, :kill)
    Process.sleep(50)
    assert Process.alive?(Process.whereis(InstanceWatcher))
  end
end
