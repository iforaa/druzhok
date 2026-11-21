defmodule Druzhok.DiskLimitTest do
  # async: false — global settings rows and the Host stub.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{DiskLimit, HostStub, Instance, Repo, Settings}

  @keys ~w(bot_disk_mb bot_disk_files disk_quota_seen disk_quota)

  setup do
    clear = fn -> Repo.delete_all(from(s in Settings, where: s.key in ^@keys)) end
    clear.()
    on_exit(clear)
    :ok
  end

  describe "bot_disk_mb" do
    test "unset is 1024, a number is itself" do
      assert Settings.bot_disk_mb() == 1024
      Settings.set("bot_disk_mb", "2048")
      assert Settings.bot_disk_mb() == 2048
    end

    test "only the exact word off turns it off; a typo is the default" do
      Settings.set("bot_disk_mb", "off")
      assert Settings.bot_disk_mb() == :off

      for typo <- ["of", "OFF", "0", "-5", "1gb", " off"] do
        Settings.set("bot_disk_mb", typo)
        assert Settings.bot_disk_mb() == 1024, "#{inspect(typo)} must not remove the limit"
      end
    end

    test "bot_disk_files is a positive integer, default 100000" do
      assert Settings.bot_disk_files() == 100_000
      Settings.set("bot_disk_files", "nope")
      assert Settings.bot_disk_files() == 100_000
      Settings.set("bot_disk_files", "5000")
      assert Settings.bot_disk_files() == 5000
    end
  end

  describe "limit" do
    test "the override wins and the file cap scales with it" do
      assert DiskLimit.limit(1024, 100_000, nil) == {1024, 100_000}
      assert DiskLimit.limit(1024, 100_000, 2048) == {2048, 200_000}
      assert DiskLimit.limit(1024, 100_000, 512) == {512, 50_000}
      assert DiskLimit.limit(1024, 100_000, 1) == {1, 97}
      assert DiskLimit.limit(1024, 1, 1) == {1, 1}
    end

    test "off is off for every bot, an override included" do
      assert DiskLimit.limit(:off, 100_000, nil) == :off
      assert DiskLimit.limit(:off, 100_000, 4096) == :off
    end

    test "reads the settings and the row" do
      Settings.set("bot_disk_mb", "2000")
      Settings.set("bot_disk_files", "1000")
      assert DiskLimit.limit(nil) == {2000, 1000}
      assert DiskLimit.limit(%Instance{disk_mb: 4000}) == {4000, 2000}
      Settings.set("bot_disk_mb", "off")
      assert DiskLimit.limit(%Instance{disk_mb: 4000}) == :off
    end
  end

  test "apply sets the row's limit through the host" do
    HostStub.use()
    inst = relay_instance(%{disk_mb: 3072})
    assert :ok = DiskLimit.apply(inst)
    assert DiskLimit.limit_by_name(inst.name) == {3072, 300_000}
    assert DiskLimit.limit_by_name("no-such-bot") == {1024, 100_000}
    Settings.set("bot_disk_mb", "off")
    assert :ok = DiskLimit.apply(inst)

    assert HostStub.quota_calls() == [{inst.name, 3072, 300_000}, {inst.name, :off, 0}]
  end

  test "Host.Process has no quotas: unknown, and no sudo" do
    assert Druzhok.Host.Process.quota("x", 1024, 100) == :unknown
    assert Druzhok.Host.Process.quota("x", :off, 0) == :unknown
    assert Druzhok.Host.Process.disk_all() == :unknown
  end

  describe "readings" do
    test "pct is the higher of size and files; a limit of 0 does not divide" do
      assert DiskLimit.pct(%{used_kb: 512, limit_kb: 1024, files: 90, file_limit: 100}) == 90.0
      assert DiskLimit.pct(%{used_kb: 1000, limit_kb: 1000, files: 1, file_limit: 100}) == 100.0
      assert DiskLimit.pct(%{used_kb: 5, limit_kb: 0, files: 5, file_limit: 0}) == nil
      assert DiskLimit.pct(%{used_kb: nil, limit_kb: nil, files: nil, file_limit: nil}) == nil
      assert DiskLimit.pct(%{used_kb: 5, limit_kb: 10, files: 5, file_limit: 0}) == 50.0
    end

    test "sizes, counts and plurals in Russian" do
      assert DiskLimit.size(245 * 1024) == "245 МБ"
      assert DiskLimit.size(0) == "0 МБ"
      assert DiskLimit.size(1024 * 1024) == "1 ГБ"
      assert DiskLimit.size(1536 * 1024) == "1,5 ГБ"
      assert DiskLimit.count(85_000) == "85 000"
      assert DiskLimit.count(100_000) == "100 000"
      assert DiskLimit.count(1_234_567) == "1 234 567"
      assert DiskLimit.count(42) == "42"

      assert Enum.map([1, 2, 5, 11, 21, 22, 112], &DiskLimit.files_word/1) ==
               ~w(файл файла файлов файлов файл файла файлов)
    end

    test "the cabinet's line shows whichever is fuller, nothing before a check or without a limit" do
      at = ~U[2026-11-21 10:00:00Z]
      base = %Instance{disk_limit_kb: 1024 * 1024, disk_file_limit: 100_000, disk_checked_at: at}

      assert DiskLimit.usage_line(%{base | disk_used_kb: 245 * 1024, disk_files: 100}) ==
               "245 МБ из 1 ГБ"

      assert DiskLimit.usage_line(%{base | disk_used_kb: 245 * 1024, disk_files: 85_000}) ==
               "85 000 файлов из 100 000"

      assert DiskLimit.usage_line(%{base | disk_used_kb: 1, disk_files: 1, disk_checked_at: nil}) ==
               nil

      assert DiskLimit.usage_line(%Instance{
               disk_used_kb: 5,
               disk_limit_kb: 0,
               disk_files: 1,
               disk_file_limit: 0,
               disk_checked_at: at
             }) == nil
    end

    test "the list column says «без лимита» only while quotas are on" do
      at = ~U[2026-11-21 10:00:00Z]

      none = %Instance{
        disk_used_kb: 5,
        disk_limit_kb: 0,
        disk_files: 1,
        disk_file_limit: 0,
        disk_checked_at: at
      }

      assert DiskLimit.short(none) == "-"
      Settings.set("disk_quota_seen", "1")
      Settings.set("disk_quota", "on")
      assert DiskLimit.short(none) == "без лимита"
      assert DiskLimit.short(%Instance{}) == "-"

      assert DiskLimit.short(%{none | disk_used_kb: 512 * 1024, disk_limit_kb: 1024 * 1024}) ==
               "512 МБ/1 ГБ 50%"
    end
  end
end
