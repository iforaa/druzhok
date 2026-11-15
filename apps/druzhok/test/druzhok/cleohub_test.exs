defmodule Druzhok.CleohubTest do
  use ExUnit.Case, async: true

  alias Druzhok.Cleohub

  @now ~U[2026-11-15 12:00:00Z]

  describe "local/3: times the model copies as they are" do
    test "the bot's zone, Russian month, no year when it is this one" do
      assert Cleohub.local(~U[2026-11-22 14:56:00Z], "Europe/Moscow", @now) == "22 ноября, 17:56 (МСК)"
      assert Cleohub.local(~U[2026-03-01 06:05:00Z], "Asia/Almaty", @now) == "1 марта, 11:05 (UTC+5)"
      assert Cleohub.local(~U[2026-07-04 12:00:00Z], "America/New_York", @now) == "4 июля, 08:00 (UTC−4)"
      assert Cleohub.local(~U[2026-01-10 10:30:00Z], "Asia/Kolkata", @now) == "10 января, 16:00 (UTC+5:30)"
      assert Cleohub.local(~U[2026-12-31 23:00:00Z], "UTC", @now) == "31 декабря, 23:00 (UTC)"
    end

    test "Moscow when the bot has no zone or an unknown one" do
      for tz <- [nil, "", "Mars/Olympus"],
          do: assert(Cleohub.local(~U[2026-11-22 14:56:00Z], tz, @now) == "22 ноября, 17:56 (МСК)")
    end

    test "the year when it differs from this one in the bot's zone" do
      assert Cleohub.local(~U[2027-01-02 09:00:00Z], "Europe/Moscow", @now) == "2 января 2027, 12:00 (МСК)"
      # Already 2027 in Moscow on New Year's Eve UTC, so no year.
      assert Cleohub.local(~U[2027-01-01 02:00:00Z], "Europe/Moscow", ~U[2026-12-31 22:00:00Z]) ==
               "1 января, 05:00 (МСК)"
    end

    test "nil stays nil" do
      assert Cleohub.local(nil, "Europe/Moscow", @now) == nil
    end
  end
end
