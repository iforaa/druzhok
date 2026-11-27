defmodule Druzhok.Ops.SandboxDriftTest do
  @moduledoc """
  `druzhok-ctl exec` runs as the bot's uid, so the bot can read its filesystem
  through /proc/<pid>/root: its sandbox must hide what hermes@.service hides.
  Both sides are read from the files, so a line added to one alone fails here.
  """
  use ExUnit.Case, async: true

  @ops Path.expand("../../../../ops", __DIR__)

  # Not sandboxing: how the unit runs, not what it may see.
  @unit_only_keys ~w(Type NotifyAccess WatchdogSec User Group EnvironmentFile Environment
                     WorkingDirectory ExecStart Restart RestartSec TimeoutStartSec KillMode CPUWeight)
  @exec_only_keys ~w(EnvironmentFile WorkingDirectory ExecSearchPath)

  # The unit has these and exec deliberately not: exec is no notify unit,
  # has an empty cgroup tree, and sees panel-save.py (panel saves run there).
  @unit_only_pairs [
    {"BindReadOnlyPaths", "/run/systemd/notify"},
    {"BindReadOnlyPaths", "/sys/fs/cgroup/system.slice/system-hermes.slice/%n"},
    {"InaccessiblePaths", "-/usr/local/lib/druzhok"}
  ]
  @exec_only_pairs [
    {"TemporaryFileSystem", "/usr/local/lib/druzhok:ro"},
    {"BindReadOnlyPaths", "/usr/local/lib/druzhok/panel-save.py"}
  ]

  # Keys systemd adds up when given again; any other key given twice means the
  # last one wins, which is how a stale value would hide.
  @list_keys ~w(TemporaryFileSystem BindPaths BindReadOnlyPaths InaccessiblePaths ReadWritePaths
                ExecSearchPath RestrictAddressFamilies)

  defp pairs(key, value) do
    case String.split(value) do
      [] -> [{key, ""}]
      parts -> Enum.map(parts, &{key, &1})
    end
  end

  defp unit_pairs do
    Path.join(@ops, "hermes@.service")
    |> File.read!()
    |> String.split("[Service]")
    |> Enum.at(1)
    |> String.split("[Install]")
    |> hd()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      if key in @unit_only_keys, do: [], else: pairs(key, value)
    end)
  end

  defp exec_props do
    text = File.read!(Path.join(@ops, "druzhok-ctl"))
    [_, rest] = String.split(text, "\n  exec)\n", parts: 2)
    [block | _] = String.split(rest, "\n    ;;", parts: 2)

    # One shell word: unquoted runs and "quoted parts", as bash joins them.
    Regex.scan(~r/-p\s+((?:[^\s"]|"[^"]*")+)/, block, capture: :all_but_first)
    |> Enum.map(fn [arg] ->
      arg = arg |> String.replace("\"", "") |> String.replace("$root", "/data/tenants/%i")
      [key, value] = String.split(arg, "=", parts: 2)
      {key, value}
    end)
    |> Enum.reject(fn {key, _} -> key in @exec_only_keys end)
  end

  defp exec_pairs, do: Enum.flat_map(exec_props(), fn {k, v} -> pairs(k, v) end)

  test "every sandbox line of the unit is on the exec line" do
    missing = (unit_pairs() -- exec_pairs()) -- @unit_only_pairs
    assert missing == [], "in hermes@.service but not in druzhok-ctl exec: #{inspect(missing)}"
  end

  test "exec adds nothing the unit does not have, beyond its named exceptions" do
    extra = (exec_pairs() -- unit_pairs()) -- @exec_only_pairs
    assert extra == [], "in druzhok-ctl exec but not in hermes@.service: #{inspect(extra)}"
  end

  test "exec gives no single-valued key twice" do
    twice =
      exec_props()
      |> Enum.reject(fn {k, _} -> k in @list_keys end)
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_, n} -> n > 1 end)

    assert twice == []
  end

  test "an empty directive counts: exec keeps CapabilityBoundingSet=" do
    assert {"CapabilityBoundingSet", ""} in exec_pairs()
    assert {"CapabilityBoundingSet", ""} in unit_pairs()
  end

  test "the exceptions are real: panel-save.py is the one helper exec sees" do
    assert {"TemporaryFileSystem", "/usr/local/lib/druzhok:ro"} in exec_pairs()
    assert {"BindReadOnlyPaths", "/usr/local/lib/druzhok/panel-save.py"} in exec_pairs()
  end
end
