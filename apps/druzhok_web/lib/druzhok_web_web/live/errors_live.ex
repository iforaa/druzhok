defmodule DruzhokWebWeb.ErrorsLive do
  use DruzhokWebWeb, :live_view

  import DruzhokWebWeb.Live.Components.ErrorsTab

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, self(), :refresh)

    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    {:ok, assign(socket,
      current_user: current_user,
      errors: Druzhok.CrashLog.recent(200),
      expanded: nil
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, errors: Druzhok.CrashLog.recent(200))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_error", %{"id" => id}, socket) do
    expanded = if to_string(socket.assigns.expanded) == id, do: nil, else: id
    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("clear_errors", _, socket) do
    Druzhok.CrashLog.clear_all()
    {:noreply, assign(socket, errors: [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <div class="w-72 bg-gray-50 border-r border-gray-200 flex flex-col">
        <div class="p-4 border-b border-gray-200">
          <a href="/" class="text-lg font-bold tracking-tight hover:text-gray-600 transition">&larr; Druzhok</a>
        </div>
        <div class="flex-1 flex items-center justify-center">
          <div class="text-center text-gray-400 text-sm">
            <div class="text-3xl mb-2">&#9888;</div>
            <div>Error Log</div>
            <div class="text-xs mt-1"><%= Druzhok.CrashLog.count() %> total</div>
          </div>
        </div>
        <div :if={@current_user} class="p-4 border-t border-gray-200">
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="text-sm font-medium truncate"><%= @current_user.email %></div>
              <div class="text-xs text-gray-400"><%= @current_user.role %></div>
            </div>
            <a href="/auth/logout" class="text-xs text-gray-400 hover:text-gray-900 transition">Logout</a>
          </div>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto">
        <.errors_tab errors={@errors} expanded={@expanded} />
      </div>
    </div>
    """
  end
end
