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

  test "check_env refuses a line break or a NUL in a value" do
    assert Systemd.check_env(%{"A" => "1", "B" => ~s(say "hi")}) == :ok

    assert Systemd.check_env(%{"T" => "123:abc\nTELEGRAM_WEBHOOK_PORT=\"20001\""}) ==
             {:error, {:bad_env, "T"}}

    assert Systemd.check_env(%{"T" => "a\rb"}) == {:error, {:bad_env, "T"}}
    assert Systemd.check_env(%{"T" => "a" <> <<0>>}) == {:error, {:bad_env, "T"}}
  end

  test "prepare refuses an env with a line break and runs nothing", %{log: log} do
    assert {:error, {:bad_env, "K"}} =
             Systemd.prepare("bot-a", %{"K" => "v\nX=\"1\""}, "/data/tenants/bot-a")

    refute File.exists?(log) and calls(log) != []
  end

  test "prepare runs create with the env on stdin, then sets the disk limit; start only starts",
       %{log: log} do
    assert :ok = Systemd.prepare("bot-a", %{"K" => "v"}, "/data/tenants/bot-a")
    assert :ok = Systemd.start("bot-a", %{"K" => "v"}, "/data/tenants/bot-a")

    assert [
             {"create", "bot-a", _, ~s(K="v")},
             {"quota", "bot-a", "1024 100000", ""},
             {"start", "bot-a", _, ""}
           ] = calls(log)
  end

  # An unlimited bot is better than a bot that is down.
  test "a failed quota call is logged and does not fail the start", %{log: log} do
    System.put_env("FAKE_CTL_QUOTA_EXIT", "1")
    on_exit(fn -> System.delete_env("FAKE_CTL_QUOTA_EXIT") end)

    output =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Systemd.prepare("bot-a", %{}, "/data/tenants/bot-a")
      end)

    assert output =~ "disk limit not set"
    assert [{"create", _, _, _}, {"quota", _, _, _}] = calls(log)
  end

  test "quota never goes through create: limits or off as arguments", %{log: log} do
    assert :ok = Systemd.quota("bot-a", 2048, 200_000)
    assert :ok = Systemd.quota("bot-a", :off, 0)
    assert {:error, :invalid_name} = Systemd.quota("../x", 1, 1)
    assert [{"quota", "bot-a", "2048 200000", ""}, {"quota", "bot-a", "off", ""}] = calls(log)

    System.put_env("FAKE_CTL_QUOTA_EXIT", "1")
    on_exit(fn -> System.delete_env("FAKE_CTL_QUOTA_EXIT") end)
    assert {:error, {:druzhok_ctl, 1, _}} = Systemd.quota("bot-a", 1, 1)

    # Exit 3: no user yet, a bot that never started. Not a failure.
    System.put_env("FAKE_CTL_QUOTA_EXIT", "3")
    assert Systemd.quota("bot-a", 1, 1) == :no_user
  end

  test "quotas asks druzhok-ctl for on or off, without a repquota", %{log: log} do
    on_exit(fn -> System.delete_env("FAKE_CTL_QUOTAS") end)
    assert Systemd.quotas() == :off
    System.put_env("FAKE_CTL_QUOTAS", "on")
    assert Systemd.quotas() == :on
    System.put_env("FAKE_CTL_QUOTAS", "maybe")
    assert {:error, _} = Systemd.quotas()
    assert Enum.all?(calls(log), &(elem(&1, 0) == "quotas"))
  end

  describe "disk_all" do
    test "reads one druzhok-ctl call: - is quotas off" do
      on_exit(fn -> System.delete_env("FAKE_CTL_DISK_ALL") end)
      assert Systemd.disk_all() == :off

      System.put_env("FAKE_CTL_DISK_ALL", "kot|2048|1048576|31|100000")

      assert Systemd.disk_all() ==
               {:ok,
                %{"kot" => %{used_kb: 2048, limit_kb: 1_048_576, files: 31, file_limit: 100_000}}}
    end

    test "parse_disk_all skips lines it cannot read" do
      out = "kot|1|2|3|4\nBad!|1|2|3|4\npes|x|2|3|4\nmur|1|2|3\nnew|0|0|0|0\n"

      assert Systemd.parse_disk_all(out) ==
               {:ok,
                %{
                  "kot" => %{used_kb: 1, limit_kb: 2, files: 3, file_limit: 4},
                  "new" => %{used_kb: 0, limit_kb: 0, files: 0, file_limit: 0}
                }}

      assert Systemd.parse_disk_all("-\n") == :off
      assert Systemd.parse_disk_all("") == {:ok, %{}}
    end
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
