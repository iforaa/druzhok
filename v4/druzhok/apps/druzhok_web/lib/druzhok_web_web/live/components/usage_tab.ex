defmodule DruzhokWebWeb.Live.Components.UsageTab do
  use Phoenix.Component

  attr :requests, :list, required: true
  attr :summary, :list, required: true
  attr :tool_stats, :list, required: true
  attr :instance_name, :string, required: true
  attr :expanded_request, :any, default: nil

  def usage_tab(assigns) do
    ~H"""
    <div class="p-5 space-y-5 max-w-5xl">
      <%!-- Summary cards --%>
      <div class="grid grid-cols-3 gap-3">
        <%= for s <- @summary do %>
          <div class="bg-raised/50 rounded-lg p-3 border border-line">
            <div class="text-[10px] text-muted uppercase font-display tracking-wider2 truncate"><%= s.model %></div>
            <div class="mt-1.5 flex items-baseline gap-2">
              <span class="text-base font-bold text-accent font-mono"><%= format_number(s.total_input) %></span>
              <span class="text-[10px] text-subtle">in</span>
              <span class="text-base font-bold text-ok font-mono"><%= format_number(s.total_output) %></span>
              <span class="text-[10px] text-subtle">out</span>
            </div>
            <div class="text-[10px] text-subtle mt-0.5"><%= s.request_count %> calls today</div>
          </div>
        <% end %>
        <div :if={@summary == []} class="col-span-3 text-center text-subtle text-xs py-4">No requests today</div>
      </div>

      <%!-- Tool execution stats --%>
      <div :if={@tool_stats != []} class="overflow-x-auto">
        <h3 class="label mb-2">Tool Usage Today</h3>
        <table class="w-full text-xs">
          <thead>
            <tr class="border-b border-line2 text-left text-[10px] text-muted uppercase tracking-wider2">
              <th class="px-2 py-1.5">Tool</th>
              <th class="px-2 py-1.5 text-right">Calls</th>
              <th class="px-2 py-1.5 text-right">Errors</th>
              <th class="px-2 py-1.5 text-right">Avg Time</th>
              <th class="px-2 py-1.5 text-right">Output</th>
            </tr>
          </thead>
          <tbody>
            <%= for t <- @tool_stats do %>
              <tr class="border-b border-line hover:bg-raised/50">
                <td class="px-2 py-1.5 font-mono"><%= t.tool_name %></td>
                <td class="px-2 py-1.5 text-right font-mono"><%= t.call_count %></td>
                <td class={"px-2 py-1.5 text-right font-mono #{if (t.error_count || 0) > 0, do: "text-err", else: "text-subtle"}"}><%= t.error_count || 0 %></td>
                <td class="px-2 py-1.5 text-right text-muted font-mono"><%= format_elapsed(round_avg(t.avg_elapsed)) %></td>
                <td class="px-2 py-1.5 text-right text-muted font-mono"><%= format_bytes(t.total_output) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Request log table --%>
      <div class="overflow-x-auto">
        <table class="w-full text-xs">
          <thead>
            <tr class="border-b border-line2 text-left text-[10px] text-muted uppercase tracking-wider2">
              <th class="px-2 py-1.5">Time</th>
              <th class="px-2 py-1.5">Type</th>
              <th class="px-2 py-1.5">Model</th>
              <th class="px-2 py-1.5 text-right">Input</th>
              <th class="px-2 py-1.5 text-right">Output</th>
              <th class="px-2 py-1.5 text-right">Total</th>
              <th class="px-2 py-1.5 text-right">Tools</th>
              <th class="px-2 py-1.5 text-right">Time</th>
            </tr>
          </thead>
          <tbody>
            <%= for req <- @requests do %>
              <tr phx-click="toggle_request" phx-value-id={req.id}
                  class={"border-b border-line cursor-pointer transition #{if @expanded_request == req.id, do: "bg-raised", else: "hover:bg-raised/50"}"}>
                <td class="px-2 py-1.5 text-muted font-mono"><%= format_time(req.inserted_at) %></td>
                <td class="px-2 py-1.5">
                  <span class={"inline-block px-1.5 py-0.5 rounded text-[10px] font-medium #{type_badge_class(req.request_type)}"}>
                    <%= req.request_type %>
                  </span>
                </td>
                <td class="px-2 py-1.5 font-mono truncate max-w-[180px] text-fg"><%= short_model(req.model) %></td>
                <td class="px-2 py-1.5 text-right text-accent font-mono">
                  <%= if req[:request_type] == "audio" and req[:audio_duration_ms] do %>
                    <%= format_duration(req.audio_duration_ms) %>
                  <% else %>
                    <%= format_number(req.input_tokens) %>
                  <% end %>
                </td>
                <td class="px-2 py-1.5 text-right text-ok font-mono"><%= format_number(req.output_tokens) %></td>
                <td class="px-2 py-1.5 text-right font-mono text-fg font-medium"><%= format_number((req.input_tokens || 0) + (req.output_tokens || 0)) %></td>
                <td class="px-2 py-1.5 text-right text-muted"><%= if req.tool_calls_count > 0, do: req.tool_calls_count, else: "-" %></td>
                <td class="px-2 py-1.5 text-right text-muted font-mono"><%= format_elapsed(req.elapsed_ms) %></td>
              </tr>
              <tr :if={@expanded_request == req.id} class="border-b border-line2">
                <td colspan="8" class="px-2 py-2">
                  <div class="space-y-2">
                    <div :if={req.prompt_preview && req.prompt_preview != ""}>
                      <div class="label mb-1">Prompt</div>
                      <pre class="text-[10px] bg-raised rounded p-2 overflow-x-auto whitespace-pre-wrap max-h-80 overflow-y-auto border border-line font-mono text-fg"><%= req.prompt_preview %></pre>
                    </div>
                    <div :if={req.response_preview && req.response_preview != ""}>
                      <div class="label mb-1">Response</div>
                      <pre class="text-[10px] bg-raised rounded p-2 overflow-x-auto whitespace-pre-wrap max-h-80 overflow-y-auto border border-line font-mono text-fg"><%= req.response_preview %></pre>
                    </div>
                    <div :if={req[:request_body] && req[:request_body] != ""}>
                      <div class="label mb-1">Full Request Body</div>
                      <pre class="text-[10px] bg-raised rounded p-2 overflow-x-auto whitespace-pre-wrap max-h-[500px] overflow-y-auto border border-line font-mono text-fg"><%= format_json(req[:request_body]) %></pre>
                    </div>
                    <div :if={(!req.prompt_preview || req.prompt_preview == "") && (!req.response_preview || req.response_preview == "") && (!req[:request_body] || req[:request_body] == "")}
                         class="text-[10px] text-subtle italic">No preview available</div>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
        <div :if={@requests == []} class="text-center text-subtle py-6 text-xs">No requests yet</div>
      </div>
    </div>
    """
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(nil), do: "0"

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> json_string
    end
  end
  defp format_json(_), do: ""

  defp format_elapsed(nil), do: "-"
  defp format_elapsed(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_elapsed(ms), do: "#{ms}ms"

  defp short_model(nil), do: "-"
  defp short_model(model), do: model |> String.split("/") |> List.last()

  defp round_avg(nil), do: nil
  defp round_avg(avg), do: round(avg)

  defp format_bytes(nil), do: "0"
  defp format_bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)}MB"
  defp format_bytes(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)}KB"
  defp format_bytes(n), do: "#{n}B"

  defp type_badge_class("chat"), do: "bg-accent/15 text-accent"
  defp type_badge_class("image"), do: "bg-warn/15 text-warn"
  defp type_badge_class("audio"), do: "bg-ok/15 text-ok"
  defp type_badge_class("embedding"), do: "bg-faint text-muted"
  defp type_badge_class(_), do: "bg-faint text-muted"

  defp format_duration(ms) when ms >= 60_000, do: "#{Float.round(ms / 60_000, 1)}m"
  defp format_duration(ms) when ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms), do: "#{ms}ms"
end
