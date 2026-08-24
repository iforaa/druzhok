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
        openrouter_api_key: mask(Druzhok.Settings.get("openrouter_api_key")),
        openrouter_api_url: Druzhok.Settings.api_url("openrouter") || "",
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
        compaction_api_url: Druzhok.Settings.get("compaction_api_url") || "",
        compaction_api_key: mask(Druzhok.Settings.get("compaction_api_key")),
        compaction_model: Druzhok.Settings.get("compaction_model") || "",
        transcription_enabled: Druzhok.Settings.get("transcription_enabled") || "true",
        transcription_model: Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001",
        image_generation_enabled: Druzhok.Settings.get("image_generation_enabled") || "false",
        image_generation_model: Druzhok.Settings.get("image_generation_model") || "google/gemini-2.5-flash-image",
        audio_tokens_per_second: Druzhok.Settings.get("audio_tokens_per_second") || "10",
        saved: false
      )}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    if val = non_masked(params["nebius_api_key"]), do: Druzhok.Settings.set("nebius_api_key", val)
    if val = non_empty(params["nebius_api_url"]), do: Druzhok.Settings.set("nebius_api_url", val)
    if val = non_masked(params["anthropic_api_key"]), do: Druzhok.Settings.set("anthropic_api_key", val)
    if val = non_empty(params["anthropic_api_url"]), do: Druzhok.Settings.set("anthropic_api_url", val)
    if val = non_masked(params["openrouter_api_key"]), do: Druzhok.Settings.set("openrouter_api_key", val)
    if val = non_empty(params["openrouter_api_url"]), do: Druzhok.Settings.set("openrouter_api_url", val)

    for key <- ["system_prompt_budget_ratio", "tool_definitions_budget_ratio",
                "history_budget_ratio", "tool_result_budget_ratio",
                "response_reserve_ratio", "default_context_window",
                "token_estimation_divisor", "embedding_api_url", "embedding_model",
                "compaction_api_url", "compaction_model", "audio_tokens_per_second"] do
      if val = non_empty(params[key]), do: Druzhok.Settings.set(key, val)
    end
    if val = non_masked(params["embedding_api_key"]), do: Druzhok.Settings.set("embedding_api_key", val)
    if val = non_masked(params["compaction_api_key"]), do: Druzhok.Settings.set("compaction_api_key", val)
    if val = non_empty(params["transcription_enabled"]), do: Druzhok.Settings.set("transcription_enabled", val)
    if val = non_empty(params["transcription_model"]), do: Druzhok.Settings.set("transcription_model", val)
    if val = non_empty(params["image_generation_enabled"]), do: Druzhok.Settings.set("image_generation_enabled", val)
    if val = non_empty(params["image_generation_model"]), do: Druzhok.Settings.set("image_generation_model", val)

    {:noreply, assign(socket,
      nebius_api_key: mask(Druzhok.Settings.get("nebius_api_key")),
      nebius_api_url: Druzhok.Settings.api_url("nebius") || "",
      anthropic_api_key: mask(Druzhok.Settings.get("anthropic_api_key")),
      anthropic_api_url: Druzhok.Settings.api_url("anthropic") || "",
      openrouter_api_key: mask(Druzhok.Settings.get("openrouter_api_key")),
      openrouter_api_url: Druzhok.Settings.api_url("openrouter") || "",
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
      compaction_api_url: Druzhok.Settings.get("compaction_api_url") || "",
      compaction_api_key: mask(Druzhok.Settings.get("compaction_api_key")),
      compaction_model: Druzhok.Settings.get("compaction_model") || "",
      transcription_enabled: Druzhok.Settings.get("transcription_enabled") || "true",
      transcription_model: Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001",
      image_generation_enabled: Druzhok.Settings.get("image_generation_enabled") || "false",
      image_generation_model: Druzhok.Settings.get("image_generation_model") || "google/gemini-2.5-flash-image",
      audio_tokens_per_second: Druzhok.Settings.get("audio_tokens_per_second") || "10",
      saved: true
    )}
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
          <.card title="Nebius (OpenAI-compatible)">
            <.field name="nebius_api_key" label="API Key" value={@nebius_api_key} placeholder="Paste new key" mono />
            <.field name="nebius_api_url" label="API URL" value={@nebius_api_url} mono />
          </.card>

          <.card title="Anthropic">
            <.field name="anthropic_api_key" label="API Key" value={@anthropic_api_key} placeholder="Paste new key" mono />
            <.field name="anthropic_api_url" label="API URL" value={@anthropic_api_url} mono />
          </.card>

          <.card title="OpenRouter">
            <.field name="openrouter_api_key" label="API Key" value={@openrouter_api_key} placeholder="Paste new key" mono />
            <.field name="openrouter_api_url" label="API URL" value={@openrouter_api_url} mono />
          </.card>

          <div class="grid grid-cols-2 gap-4">
            <.card title="Voice Transcription">
              <.field name="transcription_enabled" label="Enabled" value={@transcription_enabled} type="select" options={[{"Yes", "true"}, {"No", "false"}]} />
              <.field name="transcription_model" label="Model" value={@transcription_model} mono />
            </.card>

            <.card title="Image Generation">
              <.field name="image_generation_enabled" label="Enabled" value={@image_generation_enabled} type="select" options={[{"No", "false"}, {"Yes", "true"}]} />
              <.field name="image_generation_model" label="Model" value={@image_generation_model} mono />
            </.card>
          </div>

          <.card title="Token Budget Ratios">
            <div class="grid grid-cols-3 gap-2">
              <.field name="system_prompt_budget_ratio" label="System prompt" value={@system_prompt_ratio} mono />
              <.field name="tool_definitions_budget_ratio" label="Tool defs" value={@tool_definitions_ratio} mono />
              <.field name="history_budget_ratio" label="History" value={@history_ratio} mono />
              <.field name="tool_result_budget_ratio" label="Tool results" value={@tool_results_ratio} mono />
              <.field name="response_reserve_ratio" label="Response" value={@response_reserve_ratio} mono />
              <.field name="default_context_window" label="Context window" value={@default_context_window} mono />
            </div>
            <.field name="token_estimation_divisor" label="Token estimation divisor" value={@token_estimation_divisor} mono />
            <.field name="audio_tokens_per_second" label="Audio tokens/sec" value={@audio_tokens_per_second} mono />
          </.card>

          <.card title="Embeddings">
            <.field name="embedding_api_url" label="API URL" value={@embedding_api_url} mono placeholder="https://api.tokenfactory.nebius.com/v1" />
            <.field name="embedding_api_key" label="API Key" value={@embedding_api_key} mono placeholder="Paste key" />
            <.field name="embedding_model" label="Model" value={@embedding_model} mono placeholder="BAAI/bge-multilingual-gemma2" />
          </.card>

          <.card title="Compaction Model">
            <.field name="compaction_api_url" label="API URL" value={@compaction_api_url} mono placeholder="https://api.openai.com/v1" />
            <.field name="compaction_api_key" label="API Key" value={@compaction_api_key} mono placeholder="Paste key" />
            <.field name="compaction_model" label="Model" value={@compaction_model} mono placeholder="gpt-4o-mini" />
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
