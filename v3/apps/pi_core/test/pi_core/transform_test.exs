defmodule PiCore.TransformTest do
  use ExUnit.Case

  alias PiCore.Transform
  alias PiCore.Loop.Message
  alias PiCore.TokenBudget

  @budget TokenBudget.compute(32_000)

  describe "strip_reasoning/1" do
    test "removes reasoning from old assistant messages" do
      messages = [
        %Message{role: "assistant", content: "answer 1",
                 metadata: %{reasoning: "long thinking process here..."}},
        %Message{role: "user", content: "follow up"},
        %Message{role: "assistant", content: "answer 2",
                 metadata: %{reasoning: "more thinking"}}
      ]

      result = Transform.strip_reasoning(messages)
      first = Enum.at(result, 0)
      last = Enum.at(result, 2)
      assert first.metadata[:reasoning] == nil
      assert last.metadata[:reasoning] == "more thinking"
    end

    test "handles messages without reasoning" do
      messages = [
        %Message{role: "user", content: "hello"},
        %Message{role: "assistant", content: "hi"}
      ]
      assert Transform.strip_reasoning(messages) == messages
    end
  end

  describe "compact_tool_results/3" do
    test "compacts old tool results when over budget" do
      big_result = String.duplicate("x", 10_000)
      messages = [
        %Message{role: "toolResult", content: big_result, tool_call_id: "1", tool_name: "bash"},
        %Message{role: "assistant", content: "done"},
        %Message{role: "user", content: "more"},
        %Message{role: "toolResult", content: big_result, tool_call_id: "2", tool_name: "read"},
        %Message{role: "assistant", content: "ok"}
      ]

      small_budget = TokenBudget.compute(8_000)
      result = Transform.compact_tool_results(messages, small_budget, 4)
      first_tool = Enum.at(result, 0)
      assert first_tool.content =~ "[Tool output compacted"
    end

    test "never compacts results from current iteration" do
      big_result = String.duplicate("x", 10_000)
      messages = [
        %Message{role: "toolResult", content: big_result, tool_call_id: "1", tool_name: "bash"},
      ]

      small_budget = TokenBudget.compute(8_000)
      result = Transform.compact_tool_results(messages, small_budget, 0)
      assert Enum.at(result, 0).content == big_result
    end

    test "leaves results alone when under budget" do
      messages = [
        %Message{role: "toolResult", content: "small output", tool_call_id: "1", tool_name: "bash"},
      ]
      result = Transform.compact_tool_results(messages, @budget, 0)
      assert result == messages
    end
  end

  describe "transform_messages/3" do
    test "applies both reasoning stripping and tool compaction" do
      messages = [
        %Message{role: "assistant", content: "x", metadata: %{reasoning: "think"}},
        %Message{role: "toolResult", content: String.duplicate("y", 10_000),
                 tool_call_id: "1", tool_name: "bash"},
        %Message{role: "user", content: "ok"},
        %Message{role: "assistant", content: "done"}
      ]

      small_budget = TokenBudget.compute(8_000)
      result = Transform.transform_messages(messages, small_budget, 3)
      first = Enum.at(result, 0)
      assert first.metadata[:reasoning] == nil
    end
  end
end
