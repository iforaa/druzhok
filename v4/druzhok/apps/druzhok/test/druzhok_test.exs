defmodule DruzhokTest do
  use ExUnit.Case
  doctest Druzhok

  test "greets the world" do
    assert Druzhok.hello() == :world
  end
end
