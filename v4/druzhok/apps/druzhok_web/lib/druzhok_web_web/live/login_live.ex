defmodule DruzhokWebWeb.LoginLive do
  use DruzhokWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, error: nil, trigger_submit: false)}
  end

  @impl true
  def handle_event("login", %{"email" => email, "password" => password}, socket) do
    case Druzhok.User.authenticate(email, password) do
      {:ok, _user} ->
        {:noreply, assign(socket, trigger_submit: true)}
      {:error, _} ->
        {:noreply, assign(socket, error: "Invalid email or password")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-50">
      <div class="w-full max-w-sm">
        <div class="text-center mb-8">
          <h1 class="text-2xl font-bold">Druzhok</h1>
          <p class="text-gray-500 text-sm mt-1">Sign in to dashboard</p>
        </div>

        <div class="bg-white rounded-xl border border-gray-200 p-6 shadow-sm">
          <form phx-submit="login" action="/auth/session" method="post" phx-trigger-action={@trigger_submit}>
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Email</label>
                <input name="email" type="email" required autofocus
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900" />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Password</label>
                <input name="password" type="password" required
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900 focus:border-gray-900" />
              </div>
              <div :if={@error} class="text-red-500 text-sm"><%= @error %></div>
              <button type="submit" class="w-full bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-2 text-sm font-medium transition">
                Sign in
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
