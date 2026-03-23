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
        system_prompt_ratio: Druzhok.Settings.get("system_prompt_budget_ratio") || "0.15",
        tool_definitions_ratio: Druzhok.Settings.get("tool_definitions_budget_ratio") || "0.05",
        history_ratio: Druzhok.Settings.get("history_budget_ratio") || "0.50",
        tool_results_ratio: Druzhok.Settings.get("tool_result_budget_ratio") || "0.20",
        response_reserve_ratio: Druzhok.Settings.get("response_reserve_ratio") || "0.10",
        default_context_window: Druzhok.Settings.get("default_context_window") || "32000",
        token_estimation_divisor: Druzhok.Settings.get("token_estimation_divisor") || "4",
        embedding_api_url: Druzhok.Settings.get("embedding_api_url") || "",
        embedding_api_key: mask(Druzhok.Settings.get("embedding_api_key")),
        embedding_model: Druzhok.Settings.get("embedding_model") || "",
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

    for key <- ["system_prompt_budget_ratio", "tool_definitions_budget_ratio",
                "history_budget_ratio", "tool_result_budget_ratio",
                "response_reserve_ratio", "default_context_window",
                "token_estimation_divisor", "embedding_api_url", "embedding_model"] do
      if val = non_empty(params[key]) do
        Druzhok.Settings.set(key, val)
      end
    end
    if val = non_masked(params["embedding_api_key"]) do
      Druzhok.Settings.set("embedding_api_key", val)
    end

    {:noreply, assign(socket,
      nebius_api_key: mask(Druzhok.Settings.get("nebius_api_key")),
      nebius_api_url: Druzhok.Settings.api_url("nebius") || "",
      anthropic_api_key: mask(Druzhok.Settings.get("anthropic_api_key")),
      anthropic_api_url: Druzhok.Settings.api_url("anthropic") || "",
      system_prompt_ratio: Druzhok.Settings.get("system_prompt_budget_ratio") || "0.15",
      tool_definitions_ratio: Druzhok.Settings.get("tool_definitions_budget_ratio") || "0.05",
      history_ratio: Druzhok.Settings.get("history_budget_ratio") || "0.50",
      tool_results_ratio: Druzhok.Settings.get("tool_result_budget_ratio") || "0.20",
      response_reserve_ratio: Druzhok.Settings.get("response_reserve_ratio") || "0.10",
      default_context_window: Druzhok.Settings.get("default_context_window") || "32000",
      token_estimation_divisor: Druzhok.Settings.get("token_estimation_divisor") || "4",
      embedding_api_url: Druzhok.Settings.get("embedding_api_url") || "",
      embedding_api_key: mask(Druzhok.Settings.get("embedding_api_key")),
      embedding_model: Druzhok.Settings.get("embedding_model") || "",
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

          <div class="bg-white rounded-xl border border-gray-200 p-6">
            <h2 class="text-sm font-semibold mb-4">Token Budget Ratios</h2>
            <p class="text-xs text-gray-500 mb-4">Controls how the context window is divided. Must sum to 1.0 or less.</p>
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="block text-xs text-gray-500 mb-1">System Prompt</label>
                <input name="system_prompt_budget_ratio" value={@system_prompt_ratio}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Tool Definitions</label>
                <input name="tool_definitions_budget_ratio" value={@tool_definitions_ratio}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Conversation History</label>
                <input name="history_budget_ratio" value={@history_ratio}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Tool Results</label>
                <input name="tool_result_budget_ratio" value={@tool_results_ratio}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Response Reserve</label>
                <input name="response_reserve_ratio" value={@response_reserve_ratio}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Default Context Window</label>
                <input name="default_context_window" value={@default_context_window}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Token Estimation Divisor</label>
                <input name="token_estimation_divisor" value={@token_estimation_divisor}
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
            </div>
          </div>

          <div class="bg-white rounded-xl border border-gray-200 p-6">
            <h2 class="text-sm font-semibold mb-4">Embeddings (for memory search)</h2>
            <p class="text-xs text-gray-500 mb-4">OpenAI-compatible embeddings API. Default: Nebius (bge-multilingual-gemma2). Also supports Voyage AI, OpenAI, etc.</p>
            <div class="space-y-3">
              <div>
                <label class="block text-xs text-gray-500 mb-1">API URL</label>
                <input name="embedding_api_url" value={@embedding_api_url} placeholder="https://api.tokenfactory.nebius.com/v1"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">API Key</label>
                <input name="embedding_api_key" value={@embedding_api_key} placeholder="Paste key to update"
                       class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
              </div>
              <div>
                <label class="block text-xs text-gray-500 mb-1">Model</label>
                <input name="embedding_model" value={@embedding_model} placeholder="BAAI/bge-multilingual-gemma2"
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
