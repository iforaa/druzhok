defmodule DruzhokWebWeb.Live.Components.EventLog do
  use Phoenix.Component

  attr :events, :list, required: true

  def event_log(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div :if={@events == []} class="flex-1 flex items-center justify-center text-gray-400 text-sm">
        Waiting for events...
      </div>

      <div :if={@events != []} class="flex-1 min-h-0 overflow-y-auto">
        <div class="px-2 py-2 space-y-px">
          <div :for={event <- @events} class={"group px-4 py-2 rounded-lg #{event_bg(event.type)}"}>
            <div class="flex items-center gap-2 mb-0.5">
              <span class={"text-[10px] font-bold uppercase tracking-wider #{event_color(event.type)}"}><%= event_label(event.type) %></span>
              <span class="text-[10px] text-gray-400 font-mono"><%= format_time(event.timestamp) %></span>
            </div>
            <div class="text-sm text-gray-700 leading-relaxed whitespace-pre-wrap break-words"><%= event_text(event) %></div>
          </div>
        </div>
      </div>

      <div :if={@events != []} class="px-4 py-2 border-t border-gray-100 flex justify-end">
        <button phx-click="clear_events" class="text-xs text-gray-400 hover:text-gray-900 transition">Clear</button>
      </div>
    </div>
    """
  end

  # --- Event formatting ---

  defp event_label(:user_message), do: "in"
  defp event_label(:agent_reply), do: "out"
  defp event_label(:loop_start), do: "loop"
  defp event_label(:llm_start), do: "llm"
  defp event_label(:llm_first_token), do: "token"
  defp event_label(:llm_done), do: "llm"
  defp event_label(:llm_error), do: "llm"
  defp event_label(:tool_call), do: "tool"
  defp event_label(:tool_exec), do: "exec"
  defp event_label(:tool_result), do: "result"
  defp event_label(:heartbeat), do: "hb"
  defp event_label(:reminder), do: "remind"
  defp event_label(:error), do: "err"
  defp event_label(other), do: to_string(other)

  defp event_color(:user_message), do: "text-blue-600"
  defp event_color(:agent_reply), do: "text-green-600"
  defp event_color(:loop_start), do: "text-violet-500"
  defp event_color(:llm_start), do: "text-purple-500"
  defp event_color(:llm_first_token), do: "text-purple-400"
  defp event_color(:llm_done), do: "text-purple-500"
  defp event_color(:llm_error), do: "text-red-500"
  defp event_color(:tool_call), do: "text-amber-600"
  defp event_color(:tool_exec), do: "text-amber-500"
  defp event_color(:tool_result), do: "text-amber-500"
  defp event_color(:heartbeat), do: "text-pink-500"
  defp event_color(:reminder), do: "text-pink-500"
  defp event_color(:error), do: "text-red-500"
  defp event_color(_), do: "text-gray-400"

  defp event_bg(:user_message), do: "bg-blue-50"
  defp event_bg(:agent_reply), do: "bg-green-50"
  defp event_bg(:loop_start), do: "bg-violet-50/50"
  defp event_bg(:llm_start), do: "bg-purple-50/50"
  defp event_bg(:llm_first_token), do: "bg-purple-50/30"
  defp event_bg(:llm_done), do: "bg-purple-50/50"
  defp event_bg(:llm_error), do: "bg-red-50"
  defp event_bg(:tool_call), do: "bg-amber-50/50"
  defp event_bg(:tool_exec), do: "bg-amber-50/30"
  defp event_bg(:tool_result), do: "bg-amber-50/30"
  defp event_bg(:heartbeat), do: "bg-pink-50/50"
  defp event_bg(:reminder), do: "bg-pink-50/50"
  defp event_bg(:error), do: "bg-red-50"
  defp event_bg(_), do: "bg-gray-50/50"

  defp event_text(%{type: :user_message, text: text, sender: sender}), do: "#{sender}: #{text}"
  defp event_text(%{type: :loop_start, tool_count: tc, message_count: mc, model: m}) when is_binary(m), do: "Starting loop (#{mc} msgs, #{tc} tools) model: #{m}"
  defp event_text(%{type: :loop_start, tool_count: tc, message_count: mc}), do: "Starting loop (#{mc} msgs, #{tc} tools)"
  defp event_text(%{type: :llm_start, iteration: i, message_count: mc}), do: "Requesting LLM [iteration #{i}] (#{mc} messages)"
  defp event_text(%{type: :llm_first_token}), do: "First token received"
  defp event_text(%{type: :llm_done, iteration: i, elapsed_ms: ms, has_tool_calls: true, content_length: cl, reasoning_length: rl}) do
    "LLM responded [iteration #{i}] in #{ms}ms \u2014 #{cl} chars, #{rl} reasoning, has tool calls"
  end
  defp event_text(%{type: :llm_done, iteration: i, elapsed_ms: ms, content_length: cl, reasoning_length: rl}) do
    "LLM responded [iteration #{i}] in #{ms}ms \u2014 #{cl} chars, #{rl} reasoning"
  end
  defp event_text(%{type: :llm_error, elapsed_ms: ms, error: err}), do: "LLM error after #{ms}ms: #{err}"
  defp event_text(%{type: :tool_call, name: name, arguments: args}), do: "#{name}(#{String.slice(args, 0, 300)})"
  defp event_text(%{type: :tool_exec, name: name, elapsed_ms: ms, is_error: true}), do: "#{name} failed (#{ms}ms)"
  defp event_text(%{type: :tool_exec, name: name, elapsed_ms: ms}), do: "#{name} completed (#{ms}ms)"
  defp event_text(%{type: :tool_result, name: name, content: content, is_error: true}), do: "#{name} ERROR: #{content}"
  defp event_text(%{type: :tool_result, name: name, content: content}), do: "#{name} \u2192 #{content}"
  defp event_text(%{text: text}) when is_binary(text), do: text
  defp event_text(_), do: ""

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""
end
