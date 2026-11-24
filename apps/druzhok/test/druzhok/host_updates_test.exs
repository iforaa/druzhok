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

  test "run/2 does nothing on a host without apt's periodic dir" do
    state = %{paths: %{periodic_dir: "/nonexistent-#{System.unique_integer()}"}, reported: %{}}
    assert HostUpdates.run(state, @now) == state
  end
end
