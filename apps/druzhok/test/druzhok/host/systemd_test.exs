defmodule Druzhok.Host.SystemdTest do
  use ExUnit.Case, async: false

  alias Druzhok.Host.Systemd

  @ctl Path.expand("../../support/fake_druzhok_ctl.sh", __DIR__)

  setup do
    log = Path.join(System.tmp_dir!(), "fake-ctl-#{System.unique_integer([:positive])}.log")
    state = log <> ".state"
    System.put_env("FAKE_CTL_LOG", log)
    System.put_env("FAKE_CTL_STATE", state)
    prev = Application.get_env(:druzhok, :druzhok_ctl)
    Application.put_env(:druzhok, :druzhok_ctl, [@ctl])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:druzhok, :druzhok_ctl, prev),
        else: Application.delete_env(:druzhok, :druzhok_ctl)

      File.rm(log)
      File.rm(state)
    end)

    %{log: log}
  end

  defp calls(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn l ->
      [cmd, name, args, stdin] = String.split(l, "\t")
      {cmd, name, args, Base.decode64!(stdin)}
    end)
  end

  test "env_file serialises sorted, quoted, escaped" do
    assert Systemd.env_file(%{"B" => ~s(say "hi" \\ $X), "A" => "1"}) ==
             ~s(A="1"\nB="say \\"hi\\" \\\\ $X"\n)
  end

  test "start runs create (env on stdin) then start, every time", %{log: log} do
    assert :ok = Systemd.start("bot-a", %{"K" => "v"}, "/data/tenants/bot-a")
    assert [{"create", "bot-a", _, ~s(K="v")}, {"start", "bot-a", _, _}] = calls(log)

    File.write!(log, "")
    assert :ok = Systemd.start("bot-a", %{"K" => "v2"}, "/data/tenants/bot-a")
    assert [{"create", "bot-a", _, ~s(K="v2")}, {"start", "bot-a", _, _}] = calls(log)
  end

  test "egress_check maps curl exit code" do
    assert Systemd.egress_check("bot-e") == :closed
  end

  test "status maps words to atoms" do
    assert Systemd.status("bot-z") == :unknown
    assert :ok = Systemd.start("bot-z", %{}, "/x")
    assert Systemd.status("bot-z") == :active
    assert :ok = Systemd.stop("bot-z")
    assert Systemd.status("bot-z") == :inactive
  end

  test "stats parses mem|cpu" do
    assert Systemd.stats("bot-a") == %{mem_bytes: 123_456, cpu_usec: 7_890}
  end

  test "logs and exec pass through" do
    assert Systemd.logs("bot-a", 2) == "line1\nline2"
    assert {"hello\n", 0} = Systemd.exec("bot-a", ["echo", "hello"])
  end

  test "destroy", %{log: log} do
    assert :ok = Systemd.destroy("bot-a")
    assert [{"destroy", "bot-a", _, _}] = calls(log)
  end

  test "invalid name never reaches the helper", %{log: log} do
    assert {:error, :invalid_name} = Systemd.start("../etc", %{}, "/x")
    assert Systemd.status("X Y") == :unknown
    refute File.exists?(log)
  end
end
