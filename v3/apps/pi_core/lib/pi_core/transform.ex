defmodule PiCore.Transform do
  @moduledoc """
  Message transforms applied before LLM calls.
  Operates on copies — canonical messages stay intact.
  """

  alias PiCore.TokenEstimator
  alias PiCore.TokenBudget

  @doc "Strip reasoning from all assistant messages except the last one."
  def strip_reasoning(messages) do
    last_assistant_idx = messages
    |> Enum.with_index()
    |> Enum.filter(fn {m, _} -> m.role == "assistant" end)
    |> List.last()
    |> case do
      nil -> -1
      {_, idx} -> idx
    end

    Enum.with_index(messages, fn msg, idx ->
      if msg.role == "assistant" and idx != last_assistant_idx and is_map(msg.metadata) and msg.metadata[:reasoning] do
        %{msg | metadata: Map.delete(msg.metadata, :reasoning)}
      else
        msg
      end
    end)
  end

  @doc """
  Compact old tool results when total exceeds budget.
  Never compacts results at or after current_iteration_start index.
  """
  def compact_tool_results(messages, %TokenBudget{} = budget, current_iteration_start) do
    total = messages
    |> Enum.filter(&(&1.role == "toolResult"))
    |> Enum.reduce(0, fn m, acc -> acc + TokenEstimator.estimate(safe_content(m.content)) end)

    if total <= budget.tool_results do
      messages
    else
      do_compact_tool_results(messages, budget.tool_results, current_iteration_start)
    end
  end

  defp do_compact_tool_results(messages, budget, current_start) do
    {result, _} = Enum.reduce(Enum.with_index(messages), {[], 0}, fn {msg, idx}, {acc, running} ->
      content_text = safe_content(msg.content)
      if msg.role == "toolResult" and idx < current_start and running + TokenEstimator.estimate(content_text) > budget do
        original_size = byte_size(content_text || "")
        compacted = %{msg | content: "[Tool output compacted — #{original_size} bytes removed]"}
        {acc ++ [compacted], running + TokenEstimator.estimate(compacted.content)}
      else
        new_running = if msg.role == "toolResult", do: running + TokenEstimator.estimate(content_text), else: running
        {acc ++ [msg], new_running}
      end
    end)
    result
  end

  defp safe_content(content) when is_list(content), do: PiCore.Multimodal.to_text(content)
  defp safe_content(content), do: content

  @doc "Apply all transforms: reasoning strip then tool result compaction."
  def transform_messages(messages, %TokenBudget{} = budget, current_iteration_start) do
    messages
    |> strip_reasoning()
    |> compact_tool_results(budget, current_iteration_start)
  end
end
