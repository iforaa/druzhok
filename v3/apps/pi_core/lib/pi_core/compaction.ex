defmodule PiCore.Compaction do
  @moduledoc """
  Token-based context window compaction with iterative summarization.
  """

  alias PiCore.Loop.Message
  alias PiCore.TokenEstimator
  alias PiCore.TokenBudget
  alias PiCore.Truncate

  def maybe_compact(messages, opts) do
    case opts[:budget] do
      %TokenBudget{} = budget ->
        total_tokens = TokenEstimator.estimate_messages(messages)
        if total_tokens <= budget.history do
          {messages, false}
        else
          compact(messages, budget, opts[:llm_fn])
        end

      nil ->
        # Legacy fallback: message-count based (backward compatible)
        max = opts[:max_messages] || 40
        keep = opts[:keep_recent] || 10
        if length(messages) <= max do
          {messages, false}
        else
          legacy_compact(messages, keep, opts[:llm_fn])
        end
    end
  end

  defp compact(messages, budget, llm_fn) do
    keep_budget = TokenBudget.keep_recent_budget(budget)
    {old, recent} = split_keeping_turns(messages, keep_budget)

    {existing_summary, old_without_summary} = extract_existing_summary(old)
    version = if existing_summary, do: existing_summary.metadata[:version] + 1, else: 1

    summary_text = if llm_fn do
      generate_summary(old_without_summary, existing_summary, llm_fn)
    else
      fallback_summary(old_without_summary)
    end

    summary_cap_chars = TokenBudget.summary_cap(budget) * 4
    summary_text = Truncate.head_tail(summary_text, summary_cap_chars)

    summary_msg = %Message{
      role: "user",
      content: "[System: Compaction summary v#{version}]\n#{summary_text}",
      metadata: %{type: :compaction_summary, version: version},
      timestamp: System.os_time(:millisecond)
    }

    {[summary_msg | recent], true}
  end

  defp split_keeping_turns(messages, keep_budget) do
    {recent_reversed, _tokens} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {acc, tokens} ->
        msg_tokens = TokenEstimator.estimate_message(msg)
        new_total = tokens + msg_tokens

        if new_total > keep_budget and acc != [] and not in_tool_sequence?(msg, acc) do
          {:halt, {acc, tokens}}
        else
          {:cont, {[msg | acc], new_total}}
        end
      end)

    recent = recent_reversed
    split_idx = length(messages) - length(recent)
    old = Enum.take(messages, split_idx)
    {old, recent}
  end

  defp in_tool_sequence?(msg, following) do
    case msg.role do
      "assistant" ->
        msg.tool_calls != nil and msg.tool_calls != [] and
          match?([%{role: "toolResult"} | _], following)
      "toolResult" ->
        match?([%{role: "assistant"} | _], following)
      _ -> false
    end
  end

  defp extract_existing_summary(messages) do
    case Enum.find_index(messages, fn m ->
      is_map(m.metadata) and m.metadata[:type] == :compaction_summary
    end) do
      nil -> {nil, messages}
      idx ->
        summary = Enum.at(messages, idx)
        rest = List.delete_at(messages, idx)
        {summary, rest}
    end
  end

  defp generate_summary(messages, nil, llm_fn) do
    conversation = serialize_messages(messages)

    prompt = """
    Summarize the following conversation concisely. Use this structure:

    ## Goal
    ## Progress
    ## Key Decisions
    ## Files Read/Modified
    ## Next Steps

    Preserve UUIDs, file paths, API keys, URLs, and exact identifiers.

    <conversation>
    #{conversation}
    </conversation>
    """

    call_llm(prompt, llm_fn)
  end

  defp generate_summary(messages, existing_summary, llm_fn) do
    new_messages = serialize_messages(messages)

    prompt = """
    Update this conversation summary with the new messages below.
    Merge new information into the existing structure. Do not repeat what is already captured.

    <existing-summary>
    #{existing_summary.content}
    </existing-summary>

    <new-messages>
    #{new_messages}
    </new-messages>
    """

    call_llm(prompt, llm_fn)
  end

  defp call_llm(prompt, llm_fn) do
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

  defp serialize_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg.role
      content = msg.content
      tool_info = if msg.tool_name, do: " [#{msg.tool_name}]", else: ""
      if content, do: "[#{role}#{tool_info}]: #{String.slice(content, 0, 2000)}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp fallback_summary(messages) do
    messages
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.content)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> then(&"[Previous conversation was compacted: #{&1}]")
  end

  # Legacy message-count based compaction for backward compatibility
  defp legacy_compact(messages, keep_recent, llm_fn) do
    split_point = length(messages) - keep_recent
    {old_messages, recent_messages} = Enum.split(messages, split_point)

    summary = if llm_fn do
      call_llm(serialize_messages(old_messages), llm_fn)
    else
      fallback_summary(old_messages)
    end

    summary_msg = %Message{
      role: "user",
      content: "[System: Previous conversation was compacted. Summary:\n#{summary}]",
      metadata: %{type: :compaction_summary, version: 1},
      timestamp: System.os_time(:millisecond)
    }

    {[summary_msg | recent_messages], true}
  end
end
