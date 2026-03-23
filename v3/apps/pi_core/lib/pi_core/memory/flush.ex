defmodule PiCore.Memory.Flush do
  @moduledoc """
  Pre-compaction memory flush: extract important context from
  messages about to be discarded and save to daily memory file.
  """
  require Logger

  def flush(_messages, nil, _workspace, _timezone), do: :ok
  def flush([], _llm_fn, _workspace, _timezone), do: :ok

  def flush(messages, llm_fn, workspace, timezone) do
    conversation = messages
    |> Enum.map(fn msg ->
      if msg.content, do: "[#{msg.role}]: #{String.slice(msg.content, 0, 1000)}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")

    prompt = """
    Extract important facts, decisions, user preferences, and context worth remembering from this conversation.
    Be concise — bullet points preferred. Only extract durable information, not transient details.

    <conversation>
    #{conversation}
    </conversation>
    """

    case llm_fn.(%{
      system_prompt: "You extract and summarize important facts from conversations. Be concise and factual.",
      messages: [%{role: "user", content: prompt}],
      tools: [],
      on_delta: nil
    }) do
      {:ok, result} when result.content != nil and result.content != "" ->
        write_to_daily_file(result.content, workspace, timezone)
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Memory flush failed: #{inspect(reason)}")
        :ok
    end
  end

  defp write_to_daily_file(content, workspace, timezone) do
    date = today_in_timezone(timezone)
    time = now_in_timezone(timezone)
    file = Path.join(workspace, "memory/#{date}.md")
    File.mkdir_p!(Path.dirname(file))
    entry = "\n### #{time} (auto-flush)\n\n#{content}\n"
    File.write!(file, entry, [:append])
    :ok
  end

  defp today_in_timezone("UTC"), do: Date.utc_today() |> Date.to_string()
  defp today_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> dt |> DateTime.to_date() |> Date.to_string()
      _ -> Date.utc_today() |> Date.to_string()
    end
  end

  defp now_in_timezone("UTC"), do: DateTime.utc_now() |> Calendar.strftime("%H:%M")
  defp now_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      _ -> DateTime.utc_now() |> Calendar.strftime("%H:%M")
    end
  end
end
