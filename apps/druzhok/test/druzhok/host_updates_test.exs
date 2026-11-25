defmodule Druzhok.HostUpdatesTest do
  use ExUnit.Case, async: true

  alias Druzhok.HostUpdates

  @day 24 * 3600
  @now 1_800_000_000

  defp kinds(facts), do: facts |> HostUpdates.problems(@now) |> Enum.map(&elem(&1, 0))

  defp ok, do: %{upgrade_stamp: @now - 3600, reboot_required: nil}

  test "a healthy host reports nothing" do
    assert kinds(ok()) == []
  end

  test "upgrades older than 2 days, or never run" do
    assert kinds(%{ok() | upgrade_stamp: @now - 2 * @day + 60}) == []
    assert kinds(%{ok() | upgrade_stamp: @now - 3 * @day}) == [:upgrades_stale]
    assert kinds(%{ok() | upgrade_stamp: nil}) == [:upgrades_stale]
  end

  test "a reboot pending more than 3 days" do
    assert kinds(%{ok() | reboot_required: @now - @day}) == []
    assert kinds(%{ok() | reboot_required: @now - 4 * @day}) == [:reboot_overdue]
  end

  test "a backup older than 26 hours, or never done, once backups are set up" do
    assert kinds(Map.put(ok(), :backup_ok, :off)) == []
    assert kinds(Map.put(ok(), :backup_ok, @now - 20 * 3600)) == []
    assert kinds(Map.put(ok(), :backup_ok, @now - 27 * 3600)) == [:backup_stale]
    assert kinds(Map.put(ok(), :backup_ok, nil)) == [:backup_stale]
  end

  test "the copy of ruoc's backups, the same way" do
    assert kinds(Map.put(ok(), :mirror_ok, @now - 3600)) == []
    assert kinds(Map.put(ok(), :mirror_ok, @now - 30 * 3600)) == [:mirror_stale]
    assert kinds(Map.put(ok(), :mirror_ok, nil)) == [:mirror_stale]
  end

  test "run/2 does nothing on a host without apt's periodic dir" do
    state = %{paths: %{periodic_dir: "/nonexistent-#{System.unique_integer()}"}, reported: %{}}
    assert HostUpdates.run(state, @now) == state
  end
end
