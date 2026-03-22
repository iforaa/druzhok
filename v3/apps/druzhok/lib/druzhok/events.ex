defmodule Druzhok.Events do
  @moduledoc """
  PubSub-based event broadcasting for debugging.
  Dashboard subscribes to see messages flowing through instances.
  Also logs all events for terminal debugging.
  """

  require Logger
  @pubsub DruzhokWeb.PubSub

  def subscribe(instance_name) do
    Phoenix.PubSub.subscribe(@pubsub, topic(instance_name))
  end

  def subscribe_all do
    Phoenix.PubSub.subscribe(@pubsub, "druzhok:events:*")
  end

  def broadcast(instance_name, event) do
    event = Map.put(event, :timestamp, DateTime.utc_now())

    # Log to terminal + file
    log_event(instance_name, event)
    log_to_file(instance_name, event)

    Phoenix.PubSub.broadcast(@pubsub, topic(instance_name), {:druzhok_event, instance_name, event})
    Phoenix.PubSub.broadcast(@pubsub, "druzhok:events:*", {:druzhok_event, instance_name, event})
  end

  defp topic(name), do: "druzhok:events:#{name}"

  defp log_to_file(instance_name, event) do
    dir = Path.join([File.cwd!(), "..", "data", "instances", instance_name, "logs"])
    File.mkdir_p!(dir)
    date = Date.to_iso8601(Date.utc_today())
    path = Path.join(dir, "#{date}.log")
    ts = Calendar.strftime(event.timestamp, "%H:%M:%S")
    line = "#{ts} [#{event.type}] #{format_full(event)}\n"
    File.write!(path, line, [:append])
  rescue
    _ -> :ok
  end

  defp log_event(name, %{type: :error} = e) do
    Logger.error("[#{name}] #{format(e)}")
  end
  defp log_event(name, %{type: :llm_error} = e) do
    Logger.error("[#{name}] #{format(e)}")
  end
  defp log_event(name, e) do
    Logger.info("[#{name}] #{format(e)}")
  end

  # Full format for file logs (no truncation)
  defp format_full(%{type: :agent_reply, text: text}), do: "OUT #{text}"
  defp format_full(%{type: :tool_result, name: n, is_error: true, content: c}), do: "RESULT #{n} ERR: #{c}"
  defp format_full(%{type: :tool_result, name: n, content: c}), do: "RESULT #{n}: #{c}"
  defp format_full(event), do: format(event)

  defp format(%{type: :user_message, text: text, sender: s}), do: "IN #{s}: #{text}"
  defp format(%{type: :agent_reply, text: text}), do: "OUT #{String.slice(text, 0, 200)}"
  defp format(%{type: :loop_start, tool_count: tc, message_count: mc, model: m}) when is_binary(m), do: "LOOP start (#{mc} msgs, #{tc} tools) model=#{m}"
  defp format(%{type: :loop_start, tool_count: tc, message_count: mc}), do: "LOOP start (#{mc} msgs, #{tc} tools)"
  defp format(%{type: :llm_start, iteration: i, message_count: mc}), do: "LLM request [iter #{i}] (#{mc} msgs)"
  defp format(%{type: :llm_first_token}), do: "LLM first token"
  defp format(%{type: :llm_done, iteration: i, elapsed_ms: ms, has_tool_calls: tc}) do
    "LLM done [iter #{i}] #{ms}ms#{if tc, do: " +tools", else: ""}"
  end
  defp format(%{type: :llm_error, elapsed_ms: ms, error: err}), do: "LLM error #{ms}ms: #{err}"
  defp format(%{type: :tool_call, name: n, arguments: a}), do: "TOOL #{n}(#{String.slice(a, 0, 100)})"
  defp format(%{type: :tool_exec, name: n, elapsed_ms: ms}), do: "EXEC #{n} #{ms}ms"
  defp format(%{type: :tool_result, name: n, is_error: true, content: c}), do: "RESULT #{n} ERR: #{String.slice(c, 0, 100)}"
  defp format(%{type: :tool_result, name: n, content: c}), do: "RESULT #{n}: #{String.slice(c, 0, 100)}"
  defp format(%{type: :error, text: t}), do: "ERROR #{t}"
  defp format(%{type: type}), do: "#{type}"
end
