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
end
