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

  # Under it psutil's children() raises, so killing a background job can leave its
  # child running, and that process keeps the bot from sleeping.
  test "a bot keeps /proc's host-wide files: ProcSubset stays off" do
    refute Enum.any?(directives("hermes@.service"), &String.starts_with?(&1, "ProcSubset="))
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
