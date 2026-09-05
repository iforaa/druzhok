defmodule Druzhok.Host.ProcessTest do
  use ExUnit.Case, async: false

  alias Druzhok.Host.Process, as: HostProcess

  setup do
    name = "t-#{System.unique_integer([:positive])}"
    data_root = Path.join(System.tmp_dir!(), "host-#{name}")
    File.mkdir_p!(data_root)

    on_exit(fn ->
      HostProcess.destroy(name)
      File.rm_rf!(data_root)
    end)

    %{name: name, data_root: data_root}
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50); eventually(fun, tries - 1)
    end
  end

  test "start → active, logs show env, stop → inactive", %{name: name, data_root: root} do
    env = %{"HERMES_HOME" => root, "TELEGRAM_BOT_TOKEN" => "tok123"}
    assert :ok = HostProcess.start(name, env, root)
    assert HostProcess.status(name) == :active
    Process.sleep(300)
    logs = HostProcess.logs(name, 10)
    assert logs =~ "fake-hermes started args=gateway run"
    assert logs =~ "HERMES_HOME=#{root}"
    assert logs =~ "TELEGRAM_BOT_TOKEN=tok123"
    assert %{mem_bytes: m, cpu_usec: _} = HostProcess.stats(name)
    assert m > 0
    assert :ok = HostProcess.stop(name)
    assert HostProcess.status(name) == :inactive
  end

  test "start is idempotent", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{}, root)
    assert :ok = HostProcess.start(name, %{}, root)
    assert HostProcess.status(name) == :active
  end

  test "exited process reports :failed", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{"FAKE_HERMES_EXIT" => "3"}, root)
    assert eventually(fn -> HostProcess.status(name) == :failed end)
  end

  test "unknown / invalid names" do
    assert HostProcess.status("nope") == :inactive
    assert HostProcess.status("Bad Name") == :unknown
    assert HostProcess.stop("nope") == :ok
    assert HostProcess.logs("nope", 5) == ""
    assert HostProcess.stats("nope") == nil
  end

  test "exec runs a command with the bot's env, in its workspace", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{"HERMES_HOME" => root}, root)
    assert {out, 0} = HostProcess.exec(name, ["sh", "-c", "echo $HERMES_HOME; pwd"])
    assert [^root, cwd] = String.split(String.trim(out), "\n")
    # macOS reports /private/var for /var — compare the tail only.
    assert String.ends_with?(cwd, Path.join(Path.basename(root), "workspace"))
  end

  test "rejects invalid names, accepts underscores" do
    assert {:error, :invalid_name} = HostProcess.start("Bad Name", %{}, "/tmp")
    assert Druzhok.Host.valid_name?("vilya_fe6f")
    refute Druzhok.Host.valid_name?("../etc")
  end
end
