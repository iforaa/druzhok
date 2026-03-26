defmodule DruzhokWebWeb.Live.Components.UsageTab do
  use Phoenix.Component

  attr :requests, :list, required: true
  attr :summary, :list, required: true
  attr :instance_name, :string, required: true

  def usage_tab(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <%!-- Summary cards --%>
      <div class="grid grid-cols-3 gap-4">
        <%= for s <- @summary do %>
          <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
            <div class="text-xs text-gray-500 uppercase font-medium truncate"><%= s.model %></div>
            <div class="mt-2 flex items-baseline gap-3">
              <span class="text-lg font-bold text-blue-600"><%= format_number(s.total_input) %></span>
              <span class="text-xs text-gray-400">in</span>
              <span class="text-lg font-bold text-green-600"><%= format_number(s.total_output) %></span>
              <span class="text-xs text-gray-400">out</span>
            </div>
            <div class="text-xs text-gray-400 mt-1"><%= s.request_count %> calls today</div>
          </div>
        <% end %>
        <div :if={@summary == []} class="col-span-3 text-center text-gray-400 text-sm py-4">No requests today</div>
      </div>

      <%!-- Request log table --%>
      <div class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b border-gray-200 text-left text-xs text-gray-500 uppercase">
              <th class="px-3 py-2">Time</th>
              <th class="px-3 py-2">Model</th>
              <th class="px-3 py-2 text-right">Input</th>
              <th class="px-3 py-2 text-right">Output</th>
              <th class="px-3 py-2 text-right">Total</th>
              <th class="px-3 py-2 text-right">Tools</th>
              <th class="px-3 py-2 text-right">Time</th>
            </tr>
          </thead>
          <tbody>
            <%= for req <- @requests do %>
              <tr class="border-b border-gray-100 hover:bg-gray-50">
                <td class="px-3 py-2 text-xs text-gray-500 font-mono"><%= format_time(req.inserted_at) %></td>
                <td class="px-3 py-2 font-mono text-xs truncate max-w-[200px]"><%= short_model(req.model) %></td>
                <td class="px-3 py-2 text-right text-blue-600 font-mono"><%= format_number(req.input_tokens) %></td>
                <td class="px-3 py-2 text-right text-green-600 font-mono"><%= format_number(req.output_tokens) %></td>
                <td class="px-3 py-2 text-right font-mono font-medium"><%= format_number((req.input_tokens || 0) + (req.output_tokens || 0)) %></td>
                <td class="px-3 py-2 text-right"><%= if req.tool_calls_count > 0, do: req.tool_calls_count, else: "-" %></td>
                <td class="px-3 py-2 text-right text-gray-500 font-mono text-xs"><%= format_elapsed(req.elapsed_ms) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
        <div :if={@requests == []} class="text-center text-gray-400 py-8 text-sm">No requests yet</div>
      </div>
    </div>
    """
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(nil), do: "0"

  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_elapsed(nil), do: "-"
  defp format_elapsed(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_elapsed(ms), do: "#{ms}ms"

  defp short_model(nil), do: "-"
  defp short_model(model), do: model |> String.split("/") |> List.last()
end
