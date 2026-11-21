defmodule Druzhok.Ops.DruzhokCtlTest do
  @moduledoc """
  Runs the webhook port functions of `ops/druzhok-ctl` in bash with
  `nft`, `systemctl` and `id` stubbed, since the script itself needs root.
  """
  use ExUnit.Case, async: true

  @ctl Path.expand("../../../../ops/druzhok-ctl", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ctl-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Extract the named functions from the script and call `body` with them.
  defp run(dir, env_file, body) do
    envf = Path.join(dir, "bot.env")
    File.write!(envf, env_file)
    calls = Path.join(dir, "calls")

    functions =
      for f <- ~w(uid_of webhook_port nft_webhook_add nft_webhook_del remove_bind_lock),
          into: "" do
        [fun] = Regex.run(~r/^#{f}\(\) \{.*?^\}\n|^#{f}\(\) +\{[^\n]*\}\n/ms, File.read!(@ctl))
        fun
      end

    script = """
    set -euo pipefail
    NFT_FAMILY=inet NFT_TABLE=druzhok NFT_WEBHOOK_SET=bot_webhook
    UNIT_DIR=#{dir}/units unit=hermes@kot.service user=bot-kot envf=#{envf}
    nft() { echo "nft $*" >> #{calls}; }
    systemctl() { echo "systemctl $*" >> #{calls}; }
    id() { echo 1234; }
    #{functions}
    #{body}
    """

    {out, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert code == 0, out

    %{
      calls: if(File.exists?(calls), do: File.read!(calls), else: ""),
      units: Path.join(dir, "units")
    }
  end

  # The box's systemd ignores SocketBindAllow/Deny (no BPF_FRAMEWORK), so the
  # drop-in an earlier druzhok-ctl wrote is removed rather than kept as a
  # lock that only looks like one.
  test "a leftover bind-lock drop-in is removed, with one daemon-reload", %{dir: dir} do
    dropin = Path.join(dir, "units/hermes@kot.service.d")
    File.mkdir_p!(dropin)
    File.write!(Path.join(dropin, "webhook.conf"), "[Service]\nSocketBindDeny=any\n")

    %{calls: calls} = run(dir, ~s(TELEGRAM_WEBHOOK_PORT="20009"\n), "remove_bind_lock; remove_bind_lock")

    refute File.exists?(dropin)
    assert calls == "systemctl daemon-reload\n"
  end

  test "no drop-in, nothing to do", %{dir: dir} do
    assert %{calls: ""} = run(dir, ~s(OTHER="x"\n), "remove_bind_lock")
  end

  test "the nft element pairs the bot's uid with its port", %{dir: dir} do
    %{calls: calls} =
      run(dir, ~s(TELEGRAM_WEBHOOK_PORT="20009"\n), "nft_webhook_add; nft_webhook_del")

    assert calls ==
             "nft add element inet druzhok bot_webhook { 1234 . 20009 }\n" <>
               "nft delete element inet druzhok bot_webhook { 1234 . 20009 }\n"
  end

  test "no port, no nft element", %{dir: dir} do
    assert %{calls: ""} = run(dir, ~s(OTHER="x"\n), "nft_webhook_add")
  end

  test "a port line that is not a plain number is ignored", %{dir: dir} do
    assert %{calls: ""} = run(dir, ~s(TELEGRAM_WEBHOOK_PORT="20009; reboot"\n), "nft_webhook_add")
  end

  # The members file /etc/nftables.conf includes after druzhok.nft, so a reload
  # (`flush ruleset`) brings the sets back with their bots instead of empty.
  defp persist(dir, passwd, envs) do
    envdir = Path.join(dir, "envs")
    File.mkdir_p!(envdir)
    for {name, body} <- envs, do: File.write!(Path.join(envdir, "#{name}.env"), body)
    members = Path.join(dir, "nftables.d/druzhok.zz-members.nft")
    fun =
      for f <- ~w(nft_persist nft_persist_locked), into: "" do
        [body] = Regex.run(~r/^#{f}\(\) \{.*?^\}\n/ms, File.read!(@ctl))
        body
      end

    script = """
    set -euo pipefail
    NFT_FAMILY=inet NFT_TABLE=druzhok NFT_SET=bot_uids NFT_WEBHOOK_SET=bot_webhook
    ENVDIR=#{envdir} NFT_MEMBERS=#{members}
    getent() { printf '%s' '#{passwd}'; }
    #{fun}
    nft_persist
    """

    {out, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert code == 0, out
    {File.read!(members), File.ls!(Path.dirname(members))}
  end

  test "the saved members are every bot uid and every bot's webhook port", %{dir: dir} do
    passwd =
      "root:x:0:0::/root:/bin/bash\n" <>
        "bot-kot:x:990:990::/data/tenants/kot:/usr/sbin/nologin\n" <>
        "caddy:x:999:988::/var/lib/caddy:/usr/sbin/nologin\n" <>
        "bot-pes:x:991:991::/data/tenants/pes:/usr/sbin/nologin\n"

    {text, files} =
      persist(dir, passwd, [{"kot", ~s(TELEGRAM_WEBHOOK_PORT="20009"\n)}, {"pes", ~s(OTHER="x"\n)}])

    lines = text |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#"))

    assert lines == [
             "add element inet druzhok bot_uids { 990,991 }",
             "add element inet druzhok bot_webhook { 990 . 20009 }"
           ]

    # The temporary dot file is gone: the include glob never sees a half-written one.
    assert Enum.reject(files, &(&1 == ".druzhok-members.lock")) == ["druzhok.zz-members.nft"]
  end

  test "no bots: no add element lines, which nft would refuse empty", %{dir: dir} do
    {text, _} = persist(dir, "root:x:0:0::/root:/bin/bash\n", [])
    refute text =~ "add element"
  end

  test "a port line that is not a plain number is not saved", %{dir: dir} do
    {text, _} =
      persist(dir, "bot-kot:x:990:990::/x:/y\n", [{"kot", ~s(TELEGRAM_WEBHOOK_PORT="20009; reboot"\n)}])

    refute text =~ "bot_webhook"
  end

  # nft's include glob loads files in sorted order: the sets must be declared
  # (bootstrap installs them as druzhok.nft) before the members file adds to them.
  test "the members file sorts after the file that declares the sets" do
    bootstrap = File.read!(Path.expand("../../../../ops/bootstrap.sh", __DIR__))
    [_, decl] = Regex.run(~r{install -m 0644 "\$OPS/nftables-druzhok\.nft" /etc/nftables\.d/(\S+)}, bootstrap)
    [_, members] = Regex.run(~r{^NFT_MEMBERS=/etc/nftables\.d/(\S+)$}m, File.read!(@ctl))

    assert decl < members, "#{members} would load before #{decl} declares the sets"
  end

  test "a bot user without an env file is saved without a port, and nothing fails", %{dir: dir} do
    {text, _} = persist(dir, "bot-kot:x:990:990::/x:/y\nbot-gone:x:991:991::/x:/y\n", [{"kot", ~s(TELEGRAM_WEBHOOK_PORT="20009"\n)}])

    assert text =~ "add element inet druzhok bot_uids { 990,991 }"
    assert text =~ "add element inet druzhok bot_webhook { 990 . 20009 }"
  end

  # systemctl show answers per property; everything else is the same stub.
  defp status_of(dir, active, sub, procs \\ nil) do
    cg = Path.join(dir, "cg")
    File.mkdir_p!(cg)
    if procs, do: File.write!(Path.join(cg, "cgroup.procs"), Enum.map_join(1..procs, "", &"#{&1}\n"))

    functions =
      for f <- ~w(unit_status unit_procs), into: "" do
        [fun] = Regex.run(~r/^#{f}\(\) \{.*?^\}\n/ms, File.read!(@ctl))
        fun
      end

    script = """
    set -euo pipefail
    unit=hermes@kot.service CGROUP_ROOT=""
    systemctl() {
      case "$3" in
        ActiveState) echo #{active};;
        SubState) echo #{sub};;
        ControlGroup) echo #{cg};;
      esac
    }
    #{functions}
    echo "$(unit_status) $(unit_procs)"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    String.trim(out)
  end

  test "status tells systemd's restart loop and a drain from a start and a stop", %{dir: dir} do
    assert status_of(dir, "activating", "start") =~ ~r/^activating /
    assert status_of(dir, "activating", "auto-restart") =~ ~r/^restarting /
    assert status_of(dir, "deactivating", "stop-sigterm") =~ ~r/^stopping /
    assert status_of(dir, "active", "running") =~ ~r/^active /
    assert status_of(dir, "reloading", "x") =~ ~r/^inactive /
  end

  test "procs counts the unit's cgroup, 0 without one", %{dir: dir} do
    assert status_of(dir, "active", "running", 1) == "active 1"
    assert status_of(dir, "active", "running", 3) == "active 3"
    assert status_of(dir <> "-none", "inactive", "dead") == "inactive 0"
  end

  # The bot owns its tenant dir, so `home` or `workspace` may be a symlink it
  # planted. `install -d` there would chown and chmod the link's target as root.
  defp tenant_dirs(root) do
    [fun] = Regex.run(~r/^tenant_dirs\(\) \{.*?^\}\n/ms, File.read!(@ctl))

    script = """
    set -euo pipefail
    die() { echo "druzhok-ctl: $*" >&2; exit 1; }
    root=#{root}
    #{fun}
    tenant_dirs
    """

    System.cmd("bash", ["-c", script], stderr_to_stdout: true)
  end

  test "create makes missing home and workspace and keeps existing ones", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "workspace"))
    File.write!(Path.join(dir, "workspace/keep"), "x")

    assert {_, 0} = tenant_dirs(dir)
    assert File.dir?(Path.join(dir, "home"))
    assert File.read!(Path.join(dir, "workspace/keep")) == "x"
  end

  test "create refuses a home or workspace that is a symlink, and leaves the target alone", %{dir: dir} do
    target = Path.join(dir, "elsewhere")
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)

    for d <- ~w(home workspace) do
      root = Path.join(dir, "tenant-#{d}")
      File.mkdir_p!(root)
      File.ln_s!(target, Path.join(root, d))

      assert {out, 1} = tenant_dirs(root)
      assert out =~ "#{d} is a symlink"
    end

    assert File.stat!(target).mode |> Bitwise.band(0o777) == 0o755
    assert File.ls!(target) == []
  end

  test "the script never runs install -d below the tenant dir" do
    refute File.read!(@ctl) =~ ~r/install -d[^\n]*\$root\//
  end

  # /etc/druzhok/druzhok.env is the service's own env file, sourced by root.
  test "the name druzhok is refused before anything is written" do
    script = File.read!(@ctl) |> String.replace(~S<[ "$(id -u)" -eq 0 ] || die "must run as root">, "")
    {out, code} = System.cmd("bash", ["-c", script, "druzhok-ctl", "create", "druzhok"], stderr_to_stdout: true)
    assert code == 1
    assert out =~ "reserved bot name"
  end

  # The script with its root check off, /data/tenants moved to `tenants` and
  # `id` answering for a bot user that is there (`exists`) or not.
  defp ctl(tenants, exists, args) do
    script =
      File.read!(@ctl)
      |> String.replace(~S<[ "$(id -u)" -eq 0 ] || die "must run as root">, "")
      |> String.replace("TENANTS=/data/tenants", "TENANTS=#{tenants}")

    script = "id() { #{if exists, do: "echo 1234", else: "return 1"}; }\n" <> script
    System.cmd("bash", ["-c", script, "druzhok-ctl" | args], stderr_to_stdout: true)
  end

  describe "purge" do
    test "removes a destroyed bot's dir, and a link in it without its target", %{dir: dir} do
      outside = Path.join(dir, "outside")
      File.mkdir_p!(Path.join(dir, "tenants/kot/workspace"))
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "x")
      File.ln_s!(outside, Path.join(dir, "tenants/kot/workspace/link"))

      assert {_, 0} = ctl(Path.join(dir, "tenants"), false, ["purge", "kot"])
      refute File.exists?(Path.join(dir, "tenants/kot"))
      assert File.read!(Path.join(outside, "keep")) == "x"
      # Nothing there is fine too.
      assert {_, 0} = ctl(Path.join(dir, "tenants"), false, ["purge", "kot"])
    end

    test "refuses while the bot's user exists, a tenant dir that is a link, and a bad name", %{dir: dir} do
      tenants = Path.join(dir, "tenants")
      File.mkdir_p!(Path.join(tenants, "kot"))
      assert {out, 1} = ctl(tenants, true, ["purge", "kot"])
      assert out =~ "bot still exists"
      assert File.dir?(Path.join(tenants, "kot"))

      outside = Path.join(dir, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "x")
      File.ln_s!(outside, Path.join(tenants, "lnk"))
      assert {out, 1} = ctl(tenants, false, ["purge", "lnk"])
      assert out =~ "symlink"
      assert File.read!(Path.join(outside, "keep")) == "x"

      assert {out, 1} = ctl(tenants, false, ["purge", "../outside"])
      assert out =~ "invalid bot name"
      assert File.exists?(Path.join(outside, "keep"))
    end
  end

  # Disk limits (disk limit spec, "ops/druzhok-ctl"): the whole script with its
  # root check off and every quota tool stubbed. `quota_tools: false` leaves
  # setquota and repquota out, as on a box without the package.
  @csv """
  User,BlockStatus,FileStatus,BlockUsed,BlockSoftLimit,BlockHardLimit,BlockGrace,FileUsed,FileSoftLimit,FileHardLimit,FileGrace
  #0,ok,ok,123456,0,0,,5000,0,0,
  #990,ok,ok,2048,0,1048576,,31,0,100000,
  #991,"+-",ok,1048576,0,1048576,,10,0,100000,
  """

  @passwd "root:x:0:0::/root:/bin/bash\n" <>
            "bot-kot:x:990:990::/data/tenants/kot:/usr/sbin/nologin\n" <>
            "caddy:x:999:988::/var/lib/caddy:/usr/sbin/nologin\n" <>
            "bot-pes:x:991:991::/data/tenants/pes:/usr/sbin/nologin\n" <>
            "bot-new:x:992:992::/data/tenants/new:/usr/sbin/nologin\n"

  defp quota_ctl(dir, args, opts \\ []) do
    calls = Path.join(dir, "calls")
    File.mkdir_p!(Path.join(dir, "envs"))
    File.write!(Path.join(dir, "envs/kot.env"), ~s(TELEGRAM_WEBHOOK_PORT="20009"\n))

    script =
      File.read!(@ctl)
      |> String.replace(~S<[ "$(id -u)" -eq 0 ] || die "must run as root">, "")
      |> String.replace("TENANTS=/data/tenants", "TENANTS=#{dir}/tenants")
      |> String.replace("ENVDIR=/etc/druzhok", "ENVDIR=#{dir}/envs")
      |> String.replace("UNIT_DIR=/etc/systemd/system", "UNIT_DIR=#{dir}/units")
      |> String.replace(
        "NFT_MEMBERS=/etc/nftables.d/druzhok.zz-members.nft",
        "NFT_MEMBERS=#{dir}/nft/druzhok.zz-members.nft"
      )

    tools =
      if Keyword.get(opts, :quota_tools, true) do
        """
        setquota() { echo "setquota $*" >> #{calls}; return #{Keyword.get(opts, :setquota_exit, 0)}; }
        repquota() { echo "repquota $*" >> #{calls}; printf '%s' '#{Keyword.get(opts, :csv, @csv)}'; }
        """
      else
        ""
      end

    stubs = """
    id() { #{if Keyword.get(opts, :exists, true), do: "echo 990", else: "return 1"}; }
    findmnt() { echo "/dev/vdb /data #{Keyword.get(opts, :mount_opts, "rw,relatime,quota,usrquota")}"; }
    tune2fs() { printf 'Filesystem volume name:   druzhok-data\nFilesystem features:      #{Keyword.get(opts, :features, "has_journal ext_attr quota extent")}\n'; }
    getent() { printf '%s' '#{@passwd}'; }
    systemctl() { echo "systemctl $*" >> #{calls}; }
    nft() { :; }
    pkill() { :; }
    pgrep() { return 1; }
    userdel() { echo "userdel $*" >> #{calls}; }
    #{tools}
    """

    {out, code} =
      System.cmd("bash", ["-c", stubs <> script, "druzhok-ctl" | args],
        stderr_to_stdout: true,
        env: [{"PATH", path(dir, Keyword.get(opts, :quota_tools, true))}]
      )

    {out, code, if(File.exists?(calls), do: File.read!(calls), else: "")}
  end

  # Without the tools: a PATH of only what the script runs besides them, since
  # a dev machine may have a setquota of its own (macOS does).
  defp path(_dir, true), do: System.get_env("PATH")

  defp path(dir, false) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for tool <- ~w(awk tr sed grep cat mktemp mkdir dirname mv chmod rm rmdir sleep head flock),
        exe = System.find_executable(tool),
        not File.exists?(Path.join(bin, tool)),
        do: File.ln_s!(exe, Path.join(bin, tool))

    bin
  end

  describe "quota" do
    test "bad arguments fail, with quotas on or off", %{dir: dir} do
      for args <- [["kot"], ["kot", "0", "5"], ["kot", "abc", "5"], ["kot", "10"], ["kot", "off", "x"], ["kot", "10", "-1"]],
          tools <- [true, false] do
        assert {out, 1, ""} = quota_ctl(dir, ["quota" | args], quota_tools: tools)
        assert out =~ "usage: druzhok-ctl quota", inspect(args)
      end
    end

    test "sets hard limits only, in KB and files, on the tenants' mount", %{dir: dir} do
      assert {_, 0, calls} = quota_ctl(dir, ~w(quota kot 1024 100000))
      assert calls == "setquota -u bot-kot 0 1048576 0 100000 /data\n"
    end

    test "off clears both limits", %{dir: dir} do
      assert {_, 0, "setquota -u bot-kot 0 0 0 0 /data\n"} = quota_ctl(dir, ~w(quota kot off))
    end

    test "a setquota failure is an error", %{dir: dir} do
      assert {out, 1, _} = quota_ctl(dir, ~w(quota kot 1024 100000), setquota_exit: 1)
      assert out =~ "setquota failed for bot-kot"
    end

    # A bot that never started has no user; its first start sets the limit.
    test "a missing user: setting exits 3, clearing has nothing to do", %{dir: dir} do
      assert {out, 3, ""} = quota_ctl(dir, ~w(quota kot 1024 100000), exists: false)
      assert out =~ "no user for bot kot yet"
      assert {_, 0, ""} = quota_ctl(dir, ~w(quota kot off), exists: false)
    end
  end

  describe "quotas off" do
    # Each of the three conditions alone turns them off: the tools, the mount
    # option, the ext4 feature.
    @off [
      [quota_tools: false],
      [mount_opts: "rw,relatime"],
      [mount_opts: "rw,relatime,grpquota"],
      [features: "has_journal ext_attr extent"],
      [features: "has_journal project extent"]
    ]

    test "quota does nothing and succeeds; disk and disk-all print -; quotas says off", %{dir: dir} do
      assert {"on\n", 0, ""} = quota_ctl(dir, ~w(quotas))

      for opts <- @off do
        assert {"off\n", 0, ""} = quota_ctl(dir, ~w(quotas), opts), inspect(opts)
        assert {"", 0, ""} = quota_ctl(dir, ~w(quota kot 1024 100000), opts), inspect(opts)
        assert {"-\n", 0, ""} = quota_ctl(dir, ~w(disk kot), opts), inspect(opts)
        assert {"-\n", 0, ""} = quota_ctl(dir, ~w(disk-all), opts), inspect(opts)
      end
    end
  end

  describe "disk" do
    test "one bot's figures from repquota, by uid", %{dir: dir} do
      assert {"2048|1048576|31|100000\n", 0, calls} = quota_ctl(dir, ~w(disk kot))
      assert calls == "repquota -u -n -O csv /data\n"
    end

    test "a user repquota does not list uses nothing and has no limit", %{dir: dir} do
      assert {"0|0|0|0\n", 0, _} = quota_ctl(dir, ~w(disk kot), csv: "User,BlockStatus\n")
    end

    test "disk-all: every bot user from one repquota, no name needed", %{dir: dir} do
      assert {out, 0, calls} = quota_ctl(dir, ~w(disk-all))

      assert out ==
               "kot|2048|1048576|31|100000\n" <>
                 "pes|1048576|1048576|10|100000\n" <>
                 "new|0|0|0|0\n"

      assert calls == "repquota -u -n -O csv /data\n"
    end

    test "other commands still need a valid name", %{dir: dir} do
      assert {out, 1, _} = quota_ctl(dir, ["disk", "../x"])
      assert out =~ "invalid bot name"
    end
  end

  # Linux reuses uids: a new bot must not inherit a destroyed one's limits.
  test "destroy clears the user's limits before userdel", %{dir: dir} do
    assert {_, 0, calls} = quota_ctl(dir, ~w(destroy kot))
    lines = String.split(calls, "\n", trim: true)
    clear = Enum.find_index(lines, &(&1 == "setquota -u bot-kot 0 0 0 0 /data"))
    del = Enum.find_index(lines, &(&1 == "userdel bot-kot"))
    assert clear && del && clear < del
  end

  test "destroy with quotas off goes on without setquota", %{dir: dir} do
    assert {_, 0, calls} = quota_ctl(dir, ~w(destroy kot), quota_tools: false)
    refute calls =~ "setquota"
    assert calls =~ "userdel bot-kot"
  end

  # create rewrites the env file from stdin: never the way to set a limit.
  test "create is unchanged: it sets no limit" do
    [create] = Regex.run(~r/^  create\)\n.*?^    ;;\n/ms, File.read!(@ctl))
    refute create =~ "quota"
  end
end
