defmodule Druzhok.Ops.HermesUnitTest do
  @moduledoc "Static checks on the sandbox and CPU lines of the bots' systemd files."
  use ExUnit.Case, async: true

  @ops Path.expand("../../../../ops", __DIR__)

  defp directives(file) do
    Path.join(@ops, file)
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  test "a bot sees only its own processes and has its own IPC namespace" do
    lines = directives("hermes@.service")

    for line <- ~w(ProtectProc=invisible PrivateIPC=yes) do
      assert line in lines
    end
  end

  test "a bot cannot reach the host's D-Bus or snapd sockets" do
    lines = directives("hermes@.service")

    assert "InaccessiblePaths=-/run/dbus -/run/snapd.socket -/run/snapd-snap.socket" in lines
  end

  # Under it psutil's children() raises, so killing a background job can leave its
  # child running, and that process keeps the bot from sleeping.
  test "a bot keeps /proc's host-wide files: ProcSubset stays off" do
    refute Enum.any?(directives("hermes@.service"), &String.starts_with?(&1, "ProcSubset="))
  end

  # Visibility spec (2026-11-27): /data, /run, /var and cgroups are emptied and
  # only what the bot needs is bound back; platform dirs are hidden whole.
  test "a bot sees only its own dir and the runtime under /data" do
    lines = directives("hermes@.service")

    for line <- [
          "TemporaryFileSystem=/data:ro",
          "BindReadOnlyPaths=/data/opt",
          "BindPaths=/data/tenants/%i",
          "TemporaryFileSystem=/run:ro /var:ro",
          "TemporaryFileSystem=/usr/local/sbin:ro",
          "InaccessiblePaths=/etc/druzhok /etc/caddy /etc/systemd -/etc/nftables.d -/etc/nftables.conf",
          "InaccessiblePaths=-/usr/local/lib/druzhok -/opt/druzhok-fetch"
        ] do
      assert line in lines
    end
  end

  # With /run empty, READY=1 and the watchdog need the notify socket, and DNS
  # the stub file /etc/resolv.conf links to.
  test "the notify socket and the resolver file are bound back" do
    assert "BindReadOnlyPaths=/run/systemd/notify /run/systemd/resolve/stub-resolv.conf" in
             directives("hermes@.service")
  end

  # On systemd 255 ProtectControlGroups=yes wins over a tmpfs at the same path.
  test "cgroups: an empty tree plus the unit's own, not ProtectControlGroups=yes" do
    lines = directives("hermes@.service")

    assert "ProtectControlGroups=no" in lines
    refute "ProtectControlGroups=yes" in lines
    assert "TemporaryFileSystem=/sys/fs/cgroup:ro" in lines
    assert "BindReadOnlyPaths=/sys/fs/cgroup/system.slice/system-hermes.slice/%n" in lines
  end

  # A lower quota slows cold starts; the weight yields only under contention.
  test "bots keep one full core and yield under contention" do
    lines = directives("hermes@.service")

    assert "CPUQuota=100%" in lines
    assert "CPUWeight=50" in lines
  end

  test "the slice yields too: it is the slice that competes with druzhok and the demo" do
    assert "CPUWeight=50" in directives("system-hermes.slice")
  end
end
