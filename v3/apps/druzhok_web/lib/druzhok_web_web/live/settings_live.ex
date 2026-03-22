defmodule DruzhokWebWeb.SettingsLive do
  use DruzhokWebWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    unless current_user && current_user.role == "admin" do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok, assign(socket,
        current_user: current_user,
        nebius_api_key: mask(Druzhok.Settings.get("nebius_api_key")),
        nebius_api_url: Druzhok.Settings.api_url("nebius") || "",
        anthropic_api_key: mask(Druzhok.Settings.get("anthropic_api_key")),
        anthropic_api_url: Druzhok.Settings.api_url("anthropic") || "",
        saved: false
      )}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    if val = non_masked(params["nebius_api_key"]) do
      Druzhok.Settings.set("nebius_api_key", val)
    end
    if val = non_empty(params["nebius_api_url"]) do
      Druzhok.Settings.set("nebius_api_url", val)
    end
    if val = non_masked(params["anthropic_api_key"]) do
      Druzhok.Settings.set("anthropic_api_key", val)
    end
    if val = non_empty(params["anthropic_api_url"]) do
      Druzhok.Settings.set("anthropic_api_url", val)
    end

    {:noreply, assign(socket,
      nebius_api_key: mask(Druzhok.Settings.get("nebius_api_key")),
      nebius_api_url: Druzhok.Settings.api_url("nebius") || "",
      anthropic_api_key: mask(Druzhok.Settings.get("anthropic_api_key")),
      anthropic_api_url: Druzhok.Settings.api_url("anthropic") || "",
      saved: true
    )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-2xl mx-auto p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-xl font-bold">Settings</h1>
          <a href="/" class="text-sm text-gray-500 hover:text-gray-900">&larr; Dashboard</a>
        </div>

        <form phx-submit="save" class="space-y-6">
          <div class="bg-white rounded-xl border border-gray-200 p-6">
            <h2 class="text-sm font-semibold mb-4">Nebius (OpenAI-compatible)</h2>
            <div class="space-y-3">
              <div>
                <label class="block text-xs text-gray-500 mb-1">API Key</label>
                <input name="nebius_api_key" value={@nebius_api_key} placeholder="Paste new key to update"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">API URL</label>
                <input name="nebius_api_url" value={@nebius_api_url}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
            </div>
          </div>

          <div class="bg-white rounded-xl border border-gray-200 p-6">
            <h2 class="text-sm font-semibold mb-4">Anthropic</h2>
            <div class="space-y-3">
              <div>
                <label class="block text-xs text-gray-500 mb-1">API Key</label>
                <input name="anthropic_api_key" value={@anthropic_api_key} placeholder="Paste new key to update"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">API URL</label>
                <input name="anthropic_api_url" value={@anthropic_api_url}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
            </div>
          </div>

          <div class="flex items-center gap-3">
            <button type="submit" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-4 py-2 text-sm font-medium transition">
              Save
            </button>
            <span :if={@saved} class="text-sm text-green-600">Saved</span>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp mask(nil), do: ""
  defp mask(""), do: ""
  defp mask(key) when byte_size(key) > 8 do
    String.slice(key, 0, 4) <> String.duplicate("*", 20) <> String.slice(key, -4, 4)
  end
  defp mask(_), do: "****"

  defp non_masked(nil), do: nil
  defp non_masked(""), do: nil
  defp non_masked(val) do
    if String.contains?(val, "****"), do: nil, else: val
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(val), do: val
end
