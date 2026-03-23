defmodule PiCore.LLM.ToolCallAssemblerTest do
  use ExUnit.Case, async: true
  alias PiCore.LLM.ToolCallAssembler

  test "new returns empty state" do
    state = ToolCallAssembler.new()
    assert state.calls == []
  end

  test "start_call initializes a new tool call" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "tool_123", "my_tool")
    assert length(state.calls) == 1
    assert hd(state.calls).name == "my_tool"
  end

  test "append_args accumulates JSON fragments" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "tool_1", "bash")
    |> ToolCallAssembler.append_args(0, "{\"com")
    |> ToolCallAssembler.append_args(0, "mand\":\"ls\"}")

    [call] = ToolCallAssembler.finalize(state)
    assert call["function"]["arguments"] == "{\"command\":\"ls\"}"
  end

  test "handles multiple concurrent tool calls by index" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "t1", "bash")
    |> ToolCallAssembler.start_call(1, "t2", "read")
    |> ToolCallAssembler.append_args(0, "{\"a\":1}")
    |> ToolCallAssembler.append_args(1, "{\"b\":2}")

    calls = ToolCallAssembler.finalize(state)
    assert length(calls) == 2
  end

  test "finalize returns OpenAI-format tool_calls" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "call_abc", "read")
    |> ToolCallAssembler.append_args(0, "{\"path\":\"/tmp\"}")

    [call] = ToolCallAssembler.finalize(state)
    assert call["id"] == "call_abc"
    assert call["type"] == "function"
    assert call["function"]["name"] == "read"
    assert call["function"]["arguments"] == "{\"path\":\"/tmp\"}"
  end
end
