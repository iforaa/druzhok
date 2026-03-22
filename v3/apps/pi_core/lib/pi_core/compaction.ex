defmodule PiCore.Compaction do
  @moduledoc """
  Context window compaction. When conversation history grows too long,
  summarize older messages to free space while preserving context.
  """

  alias PiCore.Loop.Message

  @default_max_messages 40
  @default_keep_recent 10

  @doc """
  Check if compaction is needed and perform it if so.

  Returns {compacted_messages, did_compact?}

  Options:
    - max_messages: trigger compaction when message count exceeds this (default 40)
    - keep_recent: number of recent messages to preserve (default 10)
    - llm_fn: function to call LLM for summarization (required if compacting)
  """
  def maybe_compact(messages, opts \\ %{}) do
    max = opts[:max_messages] || @default_max_messages
    keep = opts[:keep_recent] || @default_keep_recent

    if length(messages) <= max do
      {messages, false}
    else
      compact(messages, keep, opts[:llm_fn])
    end
  end

  defp compact(messages, keep_recent, llm_fn) do
    # Split: old messages to summarize, recent messages to keep
    split_point = length(messages) - keep_recent
    {old_messages, recent_messages} = Enum.split(messages, split_point)

    summary = if llm_fn do
      generate_summary(old_messages, llm_fn)
    else
      # Fallback: simple concatenation of assistant messages
      old_messages
      |> Enum.filter(&(get_role(&1) == "assistant"))
      |> Enum.map(&get_content/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> then(&"[Previous conversation summary: #{&1}]")
    end

    summary_msg = %Message{
      role: "user",
      content: "[System: Previous conversation was compacted. Summary:\n#{summary}\n\nContinue the conversation from here.]",
      timestamp: System.os_time(:millisecond)
    }

    {[summary_msg | recent_messages], true}
  end

  defp generate_summary(messages, llm_fn) do
    conversation = messages
    |> Enum.map(fn msg ->
      role = get_role(msg)
      content = get_content(msg)
      if content, do: "#{role}: #{content}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")

    prompt = """
    Summarize the following conversation in 2-3 concise paragraphs.
    Preserve key facts, decisions, user preferences, and any important context.
    Do not include greetings or filler. Focus on what matters for continuing the conversation.

    #{conversation}
    """

    case llm_fn.(%{
      system_prompt: "You are a conversation summarizer. Be concise and factual.",
      messages: [%{role: "user", content: prompt}],
      tools: [],
      on_delta: nil
    }) do
      {:ok, result} -> result.content
      {:error, _} -> "Previous conversation context (summarization failed)"
    end
  end

  defp get_role(%Message{role: role}), do: role
  defp get_role(%{role: role}), do: role
  defp get_role(%{"role" => role}), do: role
  defp get_role(_), do: "unknown"

  defp get_content(%Message{content: content}), do: content
  defp get_content(%{content: content}), do: content
  defp get_content(%{"content" => content}), do: content
  defp get_content(_), do: nil
end
