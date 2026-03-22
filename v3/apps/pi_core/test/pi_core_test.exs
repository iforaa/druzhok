defmodule PiCoreTest do
  use ExUnit.Case
  doctest PiCore

  test "greets the world" do
    assert PiCore.hello() == :world
  end
end
