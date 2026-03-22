defmodule PiCore.CompactionTest do
  use ExUnit.Case

  alias PiCore.Compaction
  alias PiCore.Loop.Message

  defp make_messages(count) do
    for i <- 1..count do
      %Message{
        role: if(rem(i, 2) == 1, do: "user", else: "assistant"),
        content: "Message #{i}",
        timestamp: i
      }
    end
  end

  test "no compaction when under threshold" do
    messages = make_messages(10)
    {result, compacted?} = Compaction.maybe_compact(messages, %{max_messages: 40})
    assert result == messages
    refute compacted?
  end

  test "compacts when over threshold" do
    messages = make_messages(50)
    {result, compacted?} = Compaction.maybe_compact(messages, %{
      max_messages: 40,
      keep_recent: 10
    })
    assert compacted?
    assert length(result) <= 11  # summary + 10 recent
    # First message should be the summary
    assert hd(result).content =~ "compacted"
  end

  test "compacts with LLM summary" do
    messages = make_messages(50)
    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{content: "Summary of conversation", tool_calls: []}}
    end

    {result, compacted?} = Compaction.maybe_compact(messages, %{
      max_messages: 40,
      keep_recent: 10,
      llm_fn: mock_llm
    })
    assert compacted?
    assert hd(result).content =~ "Summary of conversation"
  end

  test "keeps recent messages intact" do
    messages = make_messages(50)
    {result, _} = Compaction.maybe_compact(messages, %{
      max_messages: 40,
      keep_recent: 5
    })
    # Last 5 messages should be preserved
    recent = Enum.take(result, -5)
    original_recent = Enum.take(messages, -5)
    assert Enum.map(recent, & &1.content) == Enum.map(original_recent, & &1.content)
  end
end
