defmodule PiCore.CompactionTest do
  use ExUnit.Case

  alias PiCore.Compaction
  alias PiCore.Loop.Message
  alias PiCore.TokenBudget

  # Small budget so tests trigger compaction with manageable message counts
  @budget TokenBudget.compute(1_000)

  defp make_messages(count, content_size \\ 50) do
    for i <- 1..count do
      %Message{
        role: if(rem(i, 2) == 1, do: "user", else: "assistant"),
        content: String.duplicate("x", content_size) <> " #{i}",
        timestamp: i
      }
    end
  end

  defp mock_llm do
    fn _opts -> {:ok, %PiCore.LLM.Client.Result{content: "Summary of conversation", tool_calls: []}} end
  end

  test "no compaction when under token budget" do
    messages = make_messages(5)
    {result, compacted?} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    assert result == messages
    refute compacted?
  end

  test "compacts when over token budget" do
    messages = make_messages(30, 200)
    {result, compacted?} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    assert compacted?
    assert length(result) < length(messages)
  end

  test "summary message has compaction_summary metadata" do
    messages = make_messages(30, 200)
    {result, true} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    summary = hd(result)
    assert summary.metadata[:type] == :compaction_summary
    assert summary.metadata[:version] == 1
  end

  test "iterative compaction increments version" do
    summary = %Message{
      role: "user",
      content: "[System: Compaction summary v1]\nPrevious summary here.",
      metadata: %{type: :compaction_summary, version: 1},
      timestamp: 0
    }
    rest = make_messages(30, 200)
    messages = [summary | rest]

    {result, true} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    new_summary = hd(result)
    assert new_summary.metadata[:version] == 2
  end

  test "keeps recent messages as complete turns" do
    messages = [
      %Message{role: "user", content: String.duplicate("a", 200), timestamp: 1},
      %Message{role: "assistant", content: "", tool_calls: [%{"id" => "1", "function" => %{"name" => "bash", "arguments" => "{}"}}], timestamp: 2},
      %Message{role: "toolResult", content: "output", tool_call_id: "1", tool_name: "bash", timestamp: 3},
      %Message{role: "assistant", content: "done", timestamp: 4}
    ] ++ make_messages(30, 200)

    {result, true} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    roles = Enum.map(result, & &1.role)
    if "toolResult" in roles do
      tr_idx = Enum.find_index(result, &(&1.role == "toolResult"))
      assert tr_idx > 0
      prev = Enum.at(result, tr_idx - 1)
      assert prev.role == "assistant"
      assert prev.tool_calls != nil
    end
  end

  test "fallback when llm_fn is nil" do
    messages = make_messages(30, 200)
    {result, compacted?} = Compaction.maybe_compact(messages, %{budget: @budget})
    assert compacted?
    summary = hd(result)
    assert summary.content =~ "compacted"
  end

  # Legacy backward compatibility tests
  test "legacy: no compaction when under threshold" do
    messages = make_messages(10)
    {result, compacted?} = Compaction.maybe_compact(messages, %{max_messages: 40})
    assert result == messages
    refute compacted?
  end

  test "legacy: compacts when over threshold" do
    messages = make_messages(50)
    {result, compacted?} = Compaction.maybe_compact(messages, %{max_messages: 40, keep_recent: 10})
    assert compacted?
    assert length(result) <= 11
    assert hd(result).content =~ "compacted"
  end
end
