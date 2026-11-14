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

  test "parse_units keeps the units that hold memory, by bot name" do
    out = """
    hermes@alpha.service   loaded active       running Hermes alpha
    hermes@beta.service    loaded activating   auto-restart Hermes beta
    hermes@gamma.service   loaded deactivating stop-sigterm Hermes gamma
    hermes@delta.service   loaded inactive     dead    Hermes delta
    ● hermes@eps.service   loaded failed       failed  Hermes eps
    hermes@zeta.service    loaded reloading    reload  Hermes zeta
    hermes@Bad!.service    loaded active       running junk
    """

    assert Systemd.parse_units(out) == %{
             "alpha" => :active,
             "beta" => :activating,
             "gamma" => :deactivating,
             "zeta" => :reloading
           }
  end

  test "holding_units lists through systemctl and is :error when it fails" do
    prev = Application.get_env(:druzhok, :systemctl_bin)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:druzhok, :systemctl_bin, prev),
        else: Application.delete_env(:druzhok, :systemctl_bin)
    end)

    Application.put_env(:druzhok, :systemctl_bin, "/bin/echo")
    assert {:ok, %{}} = Systemd.holding_units()

    Application.put_env(:druzhok, :systemctl_bin, "/usr/bin/false")
    assert Systemd.holding_units() == :error
  end

  test "env_file keeps a trailing space inside the quotes" do
    assert Systemd.env_file(%{"MNEMOSYNE_EMBEDDING_QUERY_PREFIX" => "query: "}) ==
             ~s(MNEMOSYNE_EMBEDDING_QUERY_PREFIX="query: "\n)
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

  describe "memory_bytes/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cgroup-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "hermes@up.service"))
      File.write!(Path.join([dir, "hermes@up.service", "memory.current"]), "314572800\n")
      File.mkdir_p!(Path.join(dir, "hermes@odd.service"))
      File.write!(Path.join([dir, "hermes@odd.service", "memory.current"]), "max\n")
      File.write!(Path.join([dir, "hermes@up.service", "memory.max"]), "1073741824\n")
      File.write!(Path.join([dir, "hermes@odd.service", "memory.max"]), "max\n")
      Application.put_env(:druzhok, :hermes_cgroup_dir, dir)

      on_exit(fn ->
        Application.delete_env(:druzhok, :hermes_cgroup_dir)
        File.rm_rf!(dir)
      end)
    end

    test "reads the unit's cgroup without druzhok-ctl", %{log: log} do
      assert Systemd.memory_bytes("up") == 314_572_800
      refute File.exists?(log)
    end

    test "is nil with no unit, an unreadable value or a bad name" do
      assert Systemd.memory_bytes("asleep") == nil
      assert Systemd.memory_bytes("odd") == nil
      assert Systemd.memory_bytes("../up") == nil
    end

    test "memory_max_bytes reads the limit, nil for max, no unit or a bad name", %{log: log} do
      assert Systemd.memory_max_bytes("up") == 1_073_741_824
      assert Systemd.memory_max_bytes("odd") == nil
      assert Systemd.memory_max_bytes("asleep") == nil
      assert Systemd.memory_max_bytes("../up") == nil
      refute File.exists?(log)
    end
  end

  test "exec passes through" do
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
