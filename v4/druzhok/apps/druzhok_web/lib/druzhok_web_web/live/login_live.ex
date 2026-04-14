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
    <div class="min-h-screen flex items-center justify-center bg-bg relative overflow-hidden">
      <%!-- Background: subtle scanlines + a single glowing accent dot drifting in the void --%>
      <div class="absolute inset-0 scanlines pointer-events-none"></div>
      <div class="absolute -top-32 -right-32 w-96 h-96 rounded-full bg-accent/10 blur-3xl pointer-events-none"></div>

      <div class="relative w-full max-w-[380px] px-6">
        <%!-- Brand mark --%>
        <div class="mb-10 text-center animate-reveal">
          <div class="inline-flex items-center gap-2.5 mb-3">
            <span class="w-1.5 h-1.5 bg-accent rounded-full animate-dot-pulse"></span>
            <span class="font-display text-xs font-semibold tracking-caps uppercase text-fg">Druzhok</span>
          </div>
          <p class="font-display text-[10px] uppercase tracking-caps text-subtle">
            · operator console ·
          </p>
        </div>

        <%!-- Form --%>
        <div class="bg-panel border border-line2 relative scanlines animate-reveal" style="animation-delay:80ms">
          <div class="absolute inset-x-0 top-0 h-[2px] bg-accent"></div>

          <form phx-submit="login" action="/auth/session" method="post" phx-trigger-action={@trigger_submit}
                class="p-8 space-y-5">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />

            <div>
              <label class="block font-display text-[10px] uppercase tracking-wider2 text-muted mb-1.5">email</label>
              <input name="email" type="email" required autofocus autocomplete="username"
                     class="w-full bg-transparent border-0 border-b border-line2 text-fg text-sm py-1.5 px-0
                            placeholder:text-subtle focus:outline-none focus:border-accent focus:ring-0 transition-colors" />
            </div>

            <div>
              <label class="block font-display text-[10px] uppercase tracking-wider2 text-muted mb-1.5">password</label>
              <input name="password" type="password" required autocomplete="current-password"
                     class="w-full bg-transparent border-0 border-b border-line2 text-fg text-sm py-1.5 px-0
                            placeholder:text-subtle focus:outline-none focus:border-accent focus:ring-0 transition-colors" />
            </div>

            <div :if={@error}
                 class="font-display text-xs text-err border-l-2 border-err pl-3 py-1 bg-err/5">
              <%= @error %>
            </div>

            <button type="submit"
                    class="w-full bg-accent text-bg font-display uppercase tracking-wider2 text-xs py-2.5 mt-2
                           hover:bg-fg hover:text-bg transition-colors
                           phx-submit-loading:opacity-60">
              Sign in
            </button>
          </form>
        </div>

        <p class="mt-6 text-center font-display text-[10px] uppercase tracking-wider2 text-subtle animate-reveal"
           style="animation-delay:160ms">
          ⌘K — jump to instance
        </p>
      </div>
    </div>
    """
  end
end
