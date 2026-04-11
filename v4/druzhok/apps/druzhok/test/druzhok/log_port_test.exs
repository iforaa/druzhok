defmodule Druzhok.LogPortTest do
  use ExUnit.Case, async: true

  alias Druzhok.LogPort

  describe "handle_data/2" do
    test "splits complete lines and buffers the partial tail" do
      lp = %LogPort{container: "x", port: nil, buffer: ""}

      {lines, lp} = LogPort.handle_data(lp, "first\nsecond\nthi")
      assert lines == ["first", "second"]
      assert lp.buffer == "thi"

      {lines, lp} = LogPort.handle_data(lp, "rd\nfourth")
      assert lines == ["third"]
      assert lp.buffer == "fourth"

      {lines, lp} = LogPort.handle_data(lp, "\n")
      assert lines == ["fourth"]
      assert lp.buffer == ""
    end

    test "returns no complete lines when the chunk has no newline" do
      lp = %LogPort{container: "x", port: nil, buffer: "abc"}
      {lines, lp} = LogPort.handle_data(lp, "def")
      assert lines == []
      assert lp.buffer == "abcdef"
    end

    test "strips ANSI color escapes from complete lines" do
      lp = %LogPort{container: "x", port: nil, buffer: ""}
      {lines, _} = LogPort.handle_data(lp, "\e[31mred\e[0m line\n")
      assert lines == ["red line"]
    end

    test "handles multiple blank lines" do
      lp = %LogPort{container: "x", port: nil, buffer: ""}
      {lines, lp} = LogPort.handle_data(lp, "\n\n\n")
      assert lines == ["", "", ""]
      assert lp.buffer == ""
    end

    test "accepts charlist input (to_string fallback)" do
      lp = %LogPort{container: "x", port: nil, buffer: ""}
      {lines, _} = LogPort.handle_data(lp, ~c"hello\n")
      assert lines == ["hello"]
    end
  end
end
