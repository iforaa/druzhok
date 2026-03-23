defmodule PiCore.TokenEstimatorTest do
  use ExUnit.Case

  alias PiCore.TokenEstimator
  alias PiCore.Loop.Message

  test "estimate/1 returns byte_size / 4" do
    assert TokenEstimator.estimate("hello") == 2  # 5 bytes / 4 = 1.25 -> ceil = 2
  end

  test "estimate/1 handles Cyrillic text conservatively" do
    # "Привет" = 12 bytes in UTF-8 (6 chars × 2 bytes)
    assert TokenEstimator.estimate("Привет") == 3  # 12 / 4 = 3
  end

  test "estimate/1 returns 0 for nil" do
    assert TokenEstimator.estimate(nil) == 0
  end

  test "estimate/1 returns 0 for empty string" do
    assert TokenEstimator.estimate("") == 0
  end

  test "estimate_message/1 counts content" do
    msg = %Message{role: "user", content: "Hello world"}
    assert TokenEstimator.estimate_message(msg) > 0
  end

  test "estimate_message/1 counts tool call arguments" do
    msg = %Message{
      role: "assistant",
      content: "",
      tool_calls: [
        %{"id" => "1", "function" => %{"name" => "read", "arguments" => ~s({"path":"test.txt"})}}
      ]
    }
    tokens = TokenEstimator.estimate_message(msg)
    assert tokens > 0
  end

  test "estimate_messages/1 sums all messages" do
    messages = [
      %Message{role: "user", content: "Hello"},
      %Message{role: "assistant", content: "Hi there"}
    ]
    total = TokenEstimator.estimate_messages(messages)
    assert total == TokenEstimator.estimate_message(Enum.at(messages, 0)) +
                     TokenEstimator.estimate_message(Enum.at(messages, 1))
  end

  test "estimate_tools/1 estimates OpenAI tool schemas" do
    tools = [
      %{"type" => "function", "function" => %{
        "name" => "bash",
        "description" => "Execute a shell command",
        "parameters" => %{"type" => "object", "properties" => %{"command" => %{"type" => "string"}}, "required" => ["command"]}
      }}
    ]
    assert TokenEstimator.estimate_tools(tools) > 0
  end
end
