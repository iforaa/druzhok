defmodule DruzhokWebWeb.UsageLive do
  use DruzhokWebWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(15_000, self(), :refresh)

    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    instances = Druzhok.Repo.all(Druzhok.Instance) |> Enum.map(& &1.name)

    {:ok, assign(socket,
      current_user: current_user,
      instances: instances,
      filter_instance: "",
      filter_model: "",
      summary_today: Druzhok.LlmRequest.summary_today(),
      summary_by_model: Druzhok.LlmRequest.summary_by_model(),
      requests: Druzhok.LlmRequest.recent(200)
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket,
      summary_today: Druzhok.LlmRequest.summary_today(),
      summary_by_model: Druzhok.LlmRequest.summary_by_model(),
      requests: load_requests(socket.assigns)
    )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    assigns = socket.assigns
    |> Map.put(:filter_instance, params["instance"] || "")
    |> Map.put(:filter_model, params["model"] || "")

    requests = load_requests(assigns)
    {:noreply, assign(socket, filter_instance: assigns.filter_instance, filter_model: assigns.filter_model, requests: requests)}
  end

  defp load_requests(assigns) do
    Druzhok.LlmRequest.recent_filtered(%{
      instance_name: assigns.filter_instance,
      model: assigns.filter_model,
      limit: 200
    })
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(nil), do: "0"

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <div class="w-72 bg-gray-50 border-r border-gray-200 flex flex-col">
        <div class="p-4 border-b border-gray-200">
          <a href="/" class="text-lg font-bold tracking-tight hover:text-gray-600 transition">&larr; Druzhok</a>
        </div>
        <div class="p-4 space-y-4">
          <div class="text-sm font-medium text-gray-500 uppercase tracking-wide">Token Usage</div>

          <form phx-change="filter" class="space-y-2">
            <select name="instance" class="w-full text-sm border border-gray-300 rounded px-2 py-1">
              <option value="">All instances</option>
              <%= for name <- @instances do %>
                <option value={name} selected={@filter_instance == name}><%= name %></option>
              <% end %>
            </select>
          </form>

          <div class="space-y-3">
            <div class="text-xs font-medium text-gray-500 uppercase">Today by Instance</div>
            <%= for s <- @summary_today do %>
              <div class="bg-white rounded p-2 border border-gray-200">
                <div class="text-sm font-medium"><%= s.instance_name %></div>
                <div class="text-xs text-gray-500 mt-1">
                  <span class="text-blue-600"><%= format_number(s.total_input) %> in</span> /
                  <span class="text-green-600"><%= format_number(s.total_output) %> out</span>
                  &middot; <%= s.request_count %> calls
                </div>
              </div>
            <% end %>
            <div :if={@summary_today == []} class="text-xs text-gray-400">No requests today</div>
          </div>

          <div class="space-y-3">
            <div class="text-xs font-medium text-gray-500 uppercase">Today by Model</div>
            <%= for s <- @summary_by_model do %>
              <div class="bg-white rounded p-2 border border-gray-200">
                <div class="text-sm font-medium font-mono truncate"><%= s.model %></div>
                <div class="text-xs text-gray-500 mt-1">
                  <span class="text-blue-600"><%= format_number(s.total_input) %> in</span> /
                  <span class="text-green-600"><%= format_number(s.total_output) %> out</span>
                  &middot; <%= s.request_count %> calls
                </div>
              </div>
            <% end %>
            <div :if={@summary_by_model == []} class="text-xs text-gray-400">No requests today</div>
          </div>
        </div>

        <div :if={@current_user} class="mt-auto p-4 border-t border-gray-200">
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="text-sm font-medium truncate"><%= @current_user.email %></div>
              <div class="text-xs text-gray-400"><%= @current_user.role %></div>
            </div>
            <a href="/auth/logout" class="text-xs text-gray-400 hover:text-gray-900 transition">Logout</a>
          </div>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto p-6">
        <h2 class="text-lg font-bold mb-4">Request Log</h2>
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-gray-200 text-left text-xs text-gray-500 uppercase">
                <th class="px-3 py-2">Time</th>
                <th class="px-3 py-2">Instance</th>
                <th class="px-3 py-2">Model</th>
                <th class="px-3 py-2 text-right">Input</th>
                <th class="px-3 py-2 text-right">Output</th>
                <th class="px-3 py-2 text-right">Total</th>
                <th class="px-3 py-2 text-right">Tools</th>
                <th class="px-3 py-2 text-right">Time (ms)</th>
              </tr>
            </thead>
            <tbody>
              <%= for req <- @requests do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-3 py-2 text-xs text-gray-500 font-mono"><%= format_time(req.inserted_at) %></td>
                  <td class="px-3 py-2"><%= req.instance_name %></td>
                  <td class="px-3 py-2 font-mono text-xs truncate max-w-[200px]"><%= req.model %></td>
                  <td class="px-3 py-2 text-right text-blue-600 font-mono"><%= format_number(req.input_tokens) %></td>
                  <td class="px-3 py-2 text-right text-green-600 font-mono"><%= format_number(req.output_tokens) %></td>
                  <td class="px-3 py-2 text-right font-mono font-medium"><%= format_number((req.input_tokens || 0) + (req.output_tokens || 0)) %></td>
                  <td class="px-3 py-2 text-right"><%= if req.tool_calls_count > 0, do: req.tool_calls_count, else: "-" %></td>
                  <td class="px-3 py-2 text-right text-gray-500 font-mono"><%= req.elapsed_ms %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <div :if={@requests == []} class="text-center text-gray-400 py-8">No requests yet</div>
        </div>
      </div>
    </div>
    """
  end
end
