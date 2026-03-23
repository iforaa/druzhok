defmodule PiCore.TruncateTest do
  use ExUnit.Case

  alias PiCore.Truncate

  test "returns text unchanged when under limit" do
    assert Truncate.head_tail("short text", 100) == "short text"
  end

  test "returns text unchanged when within 10% of limit" do
    text = String.duplicate("a", 95)
    assert Truncate.head_tail(text, 100) == text
  end

  test "truncates with head and tail when over limit" do
    text = String.duplicate("x", 1000)
    result = Truncate.head_tail(text, 200)
    assert byte_size(result) <= 300
    assert result =~ "[truncated"
    assert String.starts_with?(result, "x")
    assert String.ends_with?(result, "x")
  end

  test "snaps to newline boundaries" do
    lines = Enum.map(1..100, &"line #{&1}") |> Enum.join("\n")
    result = Truncate.head_tail(lines, 200)
    assert result =~ "[truncated"
    parts = String.split(result, "\n")
    refute Enum.any?(parts, &String.starts_with?(&1, "e "))
  end

  test "respects minimum max_chars of 200" do
    text = String.duplicate("a", 500)
    result = Truncate.head_tail(text, 50)
    # marker overhead may push slightly over 200
    assert byte_size(result) <= 350
  end

  test "handles nil" do
    assert Truncate.head_tail(nil, 100) == ""
  end

  test "custom head/tail ratios" do
    text = String.duplicate("x", 1000)
    result = Truncate.head_tail(text, 200, 0.5, 0.4)
    assert byte_size(result) <= 300
    assert result =~ "[truncated"
  end
end
