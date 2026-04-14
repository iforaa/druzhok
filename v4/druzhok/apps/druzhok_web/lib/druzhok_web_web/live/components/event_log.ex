defmodule DruzhokWebWeb.Live.Components.EventLog do
  use Phoenix.Component

  attr :events, :list, required: true

  def event_log(assigns) do
    ~H"""
    <div class="h-full flex flex-col bg-bg">
      <div :if={@events == []}
           class="flex-1 flex items-center justify-center text-subtle text-xs font-display uppercase tracking-wider2">
        waiting for events…
      </div>

      <div :if={@events != []} class="flex-1 min-h-0 overflow-y-auto font-mono text-[12px]">
        <div class="py-2">
          <div :for={event <- @events}
               class={[
                 "group flex gap-3 px-6 py-1 border-l-2 border-transparent hover:bg-raised/60",
                 event_hover_border(event.type)
               ]}>
            <span class="text-subtle text-[10px] pt-[3px] shrink-0 w-[56px]">
              <%= format_time(event.timestamp) %>
            </span>
            <span class={[
              "text-[10px] pt-[3px] shrink-0 w-[44px] font-display uppercase tracking-wider2",
              event_color(event.type)
            ]}>
              <%= event_label(event.type) %>
            </span>
            <span class="flex-1 text-fg leading-snug whitespace-pre-wrap break-words">
              <%= event_text(event) %>
            </span>
          </div>
        </div>
      </div>

      <div :if={@events != []} class="px-6 py-2 border-t border-line flex justify-end">
        <button phx-click="clear_events"
                class="text-[10px] font-display uppercase tracking-wider2 text-muted hover:text-accent transition-colors">
          clear buffer
        </button>
      </div>
    </div>
    """
  end

  # --- Event formatting ---

  defp event_label(:user_message), do: "in"
  defp event_label(:agent_reply), do: "out"
  defp event_label(:loop_start), do: "loop"
  defp event_label(:llm_start), do: "llm"
  defp event_label(:llm_first_token), do: "tok"
  defp event_label(:llm_done), do: "llm"
  defp event_label(:llm_error), do: "llm!"
  defp event_label(:tool_call), do: "call"
  defp event_label(:tool_exec), do: "exec"
  defp event_label(:tool_result), do: "ret"
  defp event_label(:heartbeat), do: "beat"
  defp event_label(:reminder), do: "note"
  defp event_label(:error), do: "err"
  defp event_label(other), do: to_string(other)

  # Palette: accent for human traffic, ok for successful ops, err for faults,
  # muted for scaffolding. No rainbow.
  defp event_color(:user_message), do: "text-accent"
  defp event_color(:agent_reply),  do: "text-fg"
  defp event_color(:llm_error),    do: "text-err"
  defp event_color(:error),        do: "text-err"
  defp event_color(:tool_call),    do: "text-ok"
  defp event_color(:tool_exec),    do: "text-ok"
  defp event_color(:tool_result),  do: "text-ok"
  defp event_color(:heartbeat),    do: "text-subtle"
  defp event_color(:reminder),     do: "text-subtle"
  defp event_color(_),             do: "text-muted"

  defp event_hover_border(:user_message), do: "hover:border-l-accent"
  defp event_hover_border(:agent_reply),  do: "hover:border-l-fg"
  defp event_hover_border(:llm_error),    do: "hover:border-l-err"
  defp event_hover_border(:error),        do: "hover:border-l-err"
  defp event_hover_border(:tool_call),    do: "hover:border-l-ok"
  defp event_hover_border(:tool_exec),    do: "hover:border-l-ok"
  defp event_hover_border(:tool_result),  do: "hover:border-l-ok"
  defp event_hover_border(_),             do: "hover:border-l-line2"

  defp event_text(%{type: :user_message, text: text, sender: sender}), do: "#{sender}: #{text}"
  defp event_text(%{type: :loop_start, tool_count: tc, message_count: mc, model: m}) when is_binary(m), do: "start loop · #{mc} msgs · #{tc} tools · #{m}"
  defp event_text(%{type: :loop_start, tool_count: tc, message_count: mc}), do: "start loop · #{mc} msgs · #{tc} tools"
  defp event_text(%{type: :llm_start, iteration: i, message_count: mc}), do: "llm request [##{i}] · #{mc} msgs"
  defp event_text(%{type: :llm_first_token}), do: "first token"
  defp event_text(%{type: :llm_done, iteration: i, elapsed_ms: ms, has_tool_calls: true, content_length: cl, reasoning_length: rl}) do
    "llm done [##{i}] #{ms}ms · #{cl}c · #{rl}r · +tools"
  end
  defp event_text(%{type: :llm_done, iteration: i, elapsed_ms: ms, content_length: cl, reasoning_length: rl}) do
    "llm done [##{i}] #{ms}ms · #{cl}c · #{rl}r"
  end
  defp event_text(%{type: :llm_error, elapsed_ms: ms, error: err}), do: "llm error after #{ms}ms: #{err}"
  defp event_text(%{type: :tool_call, name: name, arguments: args}), do: "#{name}(#{String.slice(args, 0, 300)})"
  defp event_text(%{type: :tool_exec, name: name, elapsed_ms: ms, is_error: true}), do: "#{name} · failed · #{ms}ms"
  defp event_text(%{type: :tool_exec, name: name, elapsed_ms: ms}), do: "#{name} · ok · #{ms}ms"
  defp event_text(%{type: :tool_result, name: name, content: content, is_error: true}), do: "#{name} ⨯ #{content}"
  defp event_text(%{type: :tool_result, name: name, content: content}), do: "#{name} → #{content}"
  defp event_text(%{text: text}) when is_binary(text), do: text
  defp event_text(_), do: ""

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""
end
