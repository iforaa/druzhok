defmodule Druzhok.ManagerBot.NamesTest do
  use ExUnit.Case, async: true

  alias Druzhok.ManagerBot.{Names, Onboarding}

  test "no name is in the pool twice" do
    all = Names.all()
    assert all -- Enum.uniq(all) == []
  end

  test "no name is a menu button, and each one fits a button" do
    for name <- Names.all() do
      refute name in Onboarding.menu_texts()
      assert String.length(name) in 2..10
    end
  end

  test "every name gives a Telegram username that starts with a letter" do
    for name <- Names.all() do
      assert Onboarding.generate_bot_username(name) =~ ~r/^[a-z][a-z0-9]+_[0-9a-f]{4}_bot$/
    end
  end

  test "pick/0 gives four names from four different groups" do
    group_of = for {group, names} <- Names.groups(), name <- names, into: %{}, do: {name, group}

    for _ <- 1..200 do
      names = Names.pick()
      assert length(names) == 4
      assert names |> Enum.map(&group_of[&1]) |> Enum.uniq() |> length() == 4
    end
  end

  test "pick/0 varies between calls" do
    assert Enum.uniq(for _ <- 1..50, do: Names.pick()) |> length() > 1
  end

  test "name_keyboard/1 lays the names out two in a row" do
    assert %{keyboard: [[%{text: "А"}, %{text: "Б"}], [%{text: "В"}, %{text: "Г"}]], one_time_keyboard: true} =
             Onboarding.name_keyboard(~w(А Б В Г))
  end
end
