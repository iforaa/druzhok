defmodule DruzhokWebWeb.SettingsLive do
  use DruzhokWebWeb, :live_view

  @keys ~w(openrouter_api_key openai_api_key manager_bot_token transcription_model
           ruoc_url ruoc_admin_host ruoc_admin_token ruoc_catalog_key)
  @secret ~w(openrouter_api_key openai_api_key manager_bot_token ruoc_admin_token ruoc_catalog_key)

  @impl true
  def mount(_params, session, socket) do
    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    unless current_user && current_user.role == "admin" do
      {:ok, redirect(socket, to: "/")}
    else
      {:ok, socket |> assign(current_user: current_user, saved: false) |> load_settings()}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    for key <- @keys do
      val = if key in @secret, do: non_masked(params[key]), else: non_empty(params[key])
      if val, do: Druzhok.Settings.set(key, val)
    end

    {:noreply, socket |> load_settings() |> assign(saved: true)}
  end

  defp load_settings(socket) do
    assign(socket,
      openrouter_api_key: mask(Druzhok.Settings.get("openrouter_api_key")),
      openai_api_key: mask(Druzhok.Settings.get("openai_api_key")),
      manager_bot_token: mask(Druzhok.Settings.get("manager_bot_token")),
      transcription_model: Druzhok.Settings.get("transcription_model") || "google/gemini-2.5-flash",
      ruoc_url: Druzhok.Settings.get("ruoc_url") || "http://127.0.0.1:8787",
      ruoc_admin_host: Druzhok.Settings.get("ruoc_admin_host") || "",
      ruoc_admin_token: mask(Druzhok.Settings.get("ruoc_admin_token")),
      ruoc_catalog_key: mask(Druzhok.Settings.get("ruoc_catalog_key"))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-bg">
      <%!-- Nav bar --%>
      <div class="border-b border-line px-6 py-3 flex items-center gap-4">
        <a href="/" class="font-display text-sm text-muted hover:text-accent transition">← Dashboard</a>
        <span class="text-faint">·</span>
        <a href="/errors" class="font-display text-[10px] uppercase tracking-wider2 text-muted hover:text-err transition">Errors</a>
        <span class="font-display text-[10px] uppercase tracking-wider2 text-accent border-b border-accent pb-0.5">Settings</span>
      </div>

      <div class="max-w-2xl mx-auto p-5">
        <form phx-submit="save" class="space-y-4">
          <.card title="OpenRouter (all LLM traffic)">
            <.field name="openrouter_api_key" label="API Key" value={@openrouter_api_key} placeholder="Paste new key" mono />
          </.card>

          <.card title="OpenAI (voice replies / TTS)">
            <.field name="openai_api_key" label="API Key" value={@openai_api_key} placeholder="Paste new key" mono />
          </.card>

          <.card title="Manager bot (Telegram)">
            <.field name="manager_bot_token" label="Bot token" value={@manager_bot_token} placeholder="123456:ABC…" mono />
            <p class="text-[10px] text-muted">Picked up within a minute, no restart needed.</p>
          </.card>

          <.card title="Voice transcription (legacy bots)">
            <.field name="transcription_model" label="OpenRouter model" value={@transcription_model} mono />
          </.card>

          <.card title="ruoc-gateway (chat, search, voice for migrated bots)">
            <.field name="ruoc_url" label="Base URL" value={@ruoc_url} mono />
            <.field name="ruoc_admin_host" label="Admin host (Host header + console link)" value={@ruoc_admin_host} placeholder="admin.example.com" mono />
            <.field name="ruoc_admin_token" label="Admin token" value={@ruoc_admin_token} placeholder="Paste ADMIN_TOKEN" mono />
            <.field name="ruoc_catalog_key" label="Catalog key (a never-funded bot key for GET /v1/models)" value={@ruoc_catalog_key} placeholder="ruoc_…" mono />
            <p class="text-[10px] text-muted">With the admin token set, every new bot gets its own ruoc account. Existing bots migrate from their Settings tab.</p>
          </.card>

          <div class="flex items-center gap-3">
            <button type="submit" class="bg-accent hover:bg-accent/80 text-bg rounded px-3 py-1.5 text-xs font-medium transition">
              Save
            </button>
            <span :if={@saved} class="text-xs text-ok">Saved</span>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # --- Components ---

  defp card(assigns) do
    ~H"""
    <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2">
      <h2 class="label"><%= @title %></h2>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, default: nil
  attr :mono, :boolean, default: false
  attr :type, :string, default: "text"
  attr :options, :list, default: []

  defp field(assigns) do
    ~H"""
    <div>
      <label class="block text-[10px] text-muted mb-0.5"><%= @label %></label>
      <%= if @type == "select" do %>
        <select name={@name} class="w-full border border-line2 rounded px-2 py-1 text-xs">
          <%= for {label, val} <- @options do %>
            <option value={val} selected={@value == val}><%= label %></option>
          <% end %>
        </select>
      <% else %>
        <input name={@name} value={@value} placeholder={@placeholder}
               class={"w-full border border-line2 rounded px-2 py-1 text-xs #{if @mono, do: "font-mono"}"} />
      <% end %>
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
  defp non_masked(val), do: if(String.contains?(val, "****"), do: nil, else: val)

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(val), do: val
end
