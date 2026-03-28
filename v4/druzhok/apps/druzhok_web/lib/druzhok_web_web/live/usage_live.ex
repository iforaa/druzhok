defmodule DruzhokWebWeb.UsageLive do
  use DruzhokWebWeb, :live_view
  import Ecto.Query, only: [from: 2]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(15_000, self(), :refresh)

    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    instances = Druzhok.Repo.all(from(i in Druzhok.Instance, select: i.name))

    {:ok, assign(socket,
      current_user: current_user,
      instances: instances,
      filter_instance: "",
      filter_model: "",
      summary_today: [],
      summary_by_model: [],
      requests: []
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", _params, socket) do
    {:noreply, socket}
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
          <div class="text-sm text-gray-400">Usage tracking will be available in a future update.</div>
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
        <div class="text-center text-gray-400 py-8">No requests yet</div>
      </div>
    </div>
    """
  end
end
