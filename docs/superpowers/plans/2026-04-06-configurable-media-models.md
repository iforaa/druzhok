# Configurable Media Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make image, audio, and embedding models configurable per bot instance instead of hardcoded.

**Architecture:** Add 3 nullable string columns to `instances` table. PoolConfig and LlmProxyController read from instance fields with fallback defaults. Dashboard gets 3 new dropdowns. ModelCatalog gets specialized model lists.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, SQLite

**Spec:** `docs/superpowers/specs/2026-04-06-configurable-media-models-design.md`

---

### Task 1: Database Migration

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260406000001_add_media_models_to_instances.exs`

- [ ] **Step 1: Create the migration file**

```elixir
defmodule Druzhok.Repo.Migrations.AddMediaModelsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :image_model, :string
      add :audio_model, :string
      add :embedding_model, :string
    end
  end
end
```

- [ ] **Step 2: Run migration**

Run: `cd v4/druzhok && DATABASE_PATH=data/druzhok.db mix ecto.migrate`
Expected: migration runs successfully, no errors.

- [ ] **Step 3: Commit**

```
git add v4/druzhok/apps/druzhok/priv/repo/migrations/20260406000001_add_media_models_to_instances.exs
```

Message: `add image_model, audio_model, embedding_model columns to instances`

---

### Task 2: Instance Schema + ModelCatalog

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex:5-36` (schema + changeset)
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex` (add specialized lists)

- [ ] **Step 1: Add fields to Instance schema**

In `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`, add 3 fields after `trigger_name`:

```elixir
    field :image_model, :string
    field :audio_model, :string
    field :embedding_model, :string
```

- [ ] **Step 2: Add fields to Instance changeset cast list**

In the `changeset/2` function, add `:image_model, :audio_model, :embedding_model` to the cast list:

```elixir
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key, :daily_token_limit, :dream_hour, :language, :tenant_key, :bot_runtime, :on_demand_model, :mention_only, :reject_message, :welcome_message, :pool_id, :allowed_telegram_ids, :trigger_name, :image_model, :audio_model, :embedding_model])
```

- [ ] **Step 3: Add specialized model lists to ModelCatalog**

In `v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex`, add after the existing `find/1` function:

```elixir
  @image_models [
    %{id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"},
    %{id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash"},
    %{id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini"},
  ]

  @audio_models [
    %{id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe"},
  ]

  @embedding_models [
    %{id: "openai/text-embedding-3-small", name: "Text Embedding 3 Small"},
  ]

  def image_models, do: @image_models
  def audio_models, do: @audio_models
  def embedding_models, do: @embedding_models
```

- [ ] **Step 4: Verify compilation**

Run: `cd v4/druzhok && mix compile`
Expected: compiles with no errors.

- [ ] **Step 5: Commit**

```
git add v4/druzhok/apps/druzhok/lib/druzhok/instance.ex v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex
```

Message: `add image/audio/embedding model fields to Instance and ModelCatalog`

---

### Task 3: PoolConfig — Read Models From Instance

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/pool_config.ex:16-100`

- [ ] **Step 1: Add default model constants**

At the top of `PoolConfig` module (after `@default_port 18800`), add:

```elixir
  @default_image_model "google/gemini-2.5-flash-lite"
  @default_audio_model "gpt-4o-mini-transcribe"
  @default_embedding_model "openai/text-embedding-3-small"
```

- [ ] **Step 2: Extract first instance's model values in `build/2`**

After the existing `first_tenant_key = List.first(instances).tenant_key` line (line 20), add:

```elixir
    first = List.first(instances)
    image_model = first.image_model || @default_image_model
    audio_model = first.audio_model || @default_audio_model
    embedding_model = first.embedding_model || @default_embedding_model
```

And change the existing `first_tenant_key` line to use `first`:

```elixir
    first_tenant_key = first.tenant_key
```

- [ ] **Step 3: Replace hardcoded embedding model**

In the `"memorySearch"` config (around line 50), change:

```elixir
            "model" => "openai/text-embedding-3-small",
```

to:

```elixir
            "model" => embedding_model,
```

- [ ] **Step 4: Replace hardcoded audio model**

In the `"audio"` config (around line 83), change:

```elixir
            "model" => "gpt-4o-mini-transcribe",
```

to:

```elixir
            "model" => audio_model,
```

- [ ] **Step 5: Replace hardcoded image model**

In the `"image"` config (around line 91), change:

```elixir
            "model" => "google/gemini-2.5-flash-lite",
```

to:

```elixir
            "model" => image_model,
```

- [ ] **Step 6: Verify compilation**

Run: `cd v4/druzhok && mix compile`
Expected: compiles with no errors.

- [ ] **Step 7: Commit**

Message: `PoolConfig: read image/audio/embedding models from instance instead of hardcoded`

---

### Task 4: LlmProxyController — Resolve Image Model From Auth Header

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:203-265`

- [ ] **Step 1: Remove the hardcoded `@image_model` module attribute**

Delete line 242:

```elixir
  @image_model "google/gemini-2.5-flash-lite"
```

- [ ] **Step 2: Add `resolve_image_model/1` private function**

Add this function near the bottom of the module (before the final `end`):

```elixir
  @default_image_model "google/gemini-2.5-flash-lite"

  defp resolve_image_model(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Druzhok.Repo.get_by(Druzhok.Instance, tenant_key: token) do
          nil -> @default_image_model
          instance -> instance.image_model || @default_image_model
        end
      _ -> @default_image_model
    end
  end
```

- [ ] **Step 3: Update `responses_proxy/2` to resolve model dynamically**

In the `responses_proxy/2` function (line 203), change:

```elixir
    chat_body = convert_responses_to_chat(body)
```

to:

```elixir
    image_model = resolve_image_model(conn)
    chat_body = convert_responses_to_chat(body, image_model)
```

- [ ] **Step 4: Update `convert_responses_to_chat` to accept model parameter**

Change the function signature and body — replace:

```elixir
  defp convert_responses_to_chat(body) do
    # Override model — OpenClaw sends OpenAI model names but we route to OpenRouter
    model = @image_model
```

with:

```elixir
  defp convert_responses_to_chat(body, model) do
```

(Remove the `model = @image_model` line — `model` now comes from the parameter.)

- [ ] **Step 5: Verify compilation**

Run: `cd v4/druzhok && mix compile`
Expected: compiles with no errors.

- [ ] **Step 6: Commit**

Message: `LlmProxyController: resolve image model from tenant auth header`

---

### Task 5: Dashboard UI — Add Model Dropdowns

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex:720-728` (event handler)
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex:964-985` (template)

- [ ] **Step 1: Update the `update_models` event handler**

In `handle_event("update_models", ...)` (line 720), replace:

```elixir
  def handle_event("update_models", %{"name" => name, "default_model" => default_model} = params, socket) do
    on_demand = case params["on_demand_model"] do
      "" -> nil
      nil -> nil
      model -> model
    end

    update_instance_field(name, %{model: default_model, on_demand_model: on_demand})
    {:noreply, assign(socket, instances: list_instances())}
  end
```

with:

```elixir
  def handle_event("update_models", %{"name" => name, "default_model" => default_model} = params, socket) do
    on_demand = case params["on_demand_model"] do
      "" -> nil
      nil -> nil
      model -> model
    end

    changes = %{model: default_model, on_demand_model: on_demand}
    changes = if p = non_empty_param(params, "image_model"), do: Map.put(changes, :image_model, p), else: changes
    changes = if p = non_empty_param(params, "audio_model"), do: Map.put(changes, :audio_model, p), else: changes
    changes = if p = non_empty_param(params, "embedding_model"), do: Map.put(changes, :embedding_model, p), else: changes

    update_instance_field(name, changes)
    {:noreply, assign(socket, instances: list_instances())}
  end

  defp non_empty_param(params, key) do
    case params[key] do
      nil -> nil
      "" -> nil
      val -> val
    end
  end
```

- [ ] **Step 2: Add dropdowns to the template**

After the closing `</div>` of the existing 2-column grid (line 984), but still inside the `<form phx-change="update_models">` (before `</form>` on line 985), add:

```heex
                  <div class="grid grid-cols-3 gap-4 mt-4">
                    <div>
                      <label class="block text-xs font-medium text-gray-500 mb-1">Image model</label>
                      <select name="image_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                        <%= for m <- Druzhok.ModelCatalog.image_models() do %>
                          <option value={m.id} selected={m.id == (selected_field(@instances, @selected, :image_model) || "google/gemini-2.5-flash-lite")}><%= m.name %></option>
                        <% end %>
                      </select>
                    </div>
                    <div>
                      <label class="block text-xs font-medium text-gray-500 mb-1">Audio model</label>
                      <select name="audio_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                        <%= for m <- Druzhok.ModelCatalog.audio_models() do %>
                          <option value={m.id} selected={m.id == (selected_field(@instances, @selected, :audio_model) || "gpt-4o-mini-transcribe")}><%= m.name %></option>
                        <% end %>
                      </select>
                    </div>
                    <div>
                      <label class="block text-xs font-medium text-gray-500 mb-1">Embedding model</label>
                      <select name="embedding_model" disabled={is_running} class={"w-full border border-gray-300 rounded-lg px-3 py-2 text-sm #{if is_running, do: "opacity-50 cursor-not-allowed"}"}>
                        <%= for m <- Druzhok.ModelCatalog.embedding_models() do %>
                          <option value={m.id} selected={m.id == (selected_field(@instances, @selected, :embedding_model) || "openai/text-embedding-3-small")}><%= m.name %></option>
                        <% end %>
                      </select>
                    </div>
                  </div>
```

- [ ] **Step 3: Verify compilation**

Run: `cd v4/druzhok && mix compile`
Expected: compiles with no errors.

- [ ] **Step 4: Verify locally in browser**

Run: `cd v4/druzhok && DATABASE_PATH=data/druzhok.db mix phx.server`
Navigate to dashboard, select an instance, check the Settings tab. Verify:
- 3 new dropdowns appear below Default/Smart model selectors
- Changing a dropdown value persists (page reload shows saved value)
- Dropdowns are disabled when the bot is running

- [ ] **Step 5: Commit**

Message: `dashboard: add image/audio/embedding model dropdowns to instance settings`

---

### Task 6: Deploy and E2E Test

- [ ] **Step 1: Deploy to server**

```bash
ssh -l igor 158.160.78.230
cd ~/druzhok && git pull
source ~/.bashrc; . ~/.asdf/asdf.sh
cd v4/druzhok && mix compile
DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate
sudo systemctl restart druzhok
```

- [ ] **Step 2: Verify dashboard**

Open the dashboard in browser. Select a bot instance, go to Settings tab. Confirm the 3 new dropdowns show with correct defaults.

- [ ] **Step 3: Test image understanding**

Send an image to a bot in Telegram with a question like "What do you see?". Check server logs:

```bash
journalctl -u druzhok --since '2 min ago' | grep responses
```

Expected: log shows `model=google/gemini-2.5-flash-lite` (or whatever is configured). Bot responds with image description.

- [ ] **Step 4: Test audio transcription**

Send a voice message to a bot in Telegram. Check logs:

```bash
journalctl -u druzhok --since '2 min ago' | grep audio
```

Expected: log shows transcription success. Bot responds to voice content.

- [ ] **Step 5: Test memory/embeddings**

Ask the bot to recall something from a previous conversation (triggering memory search). Check that the response works — embedding model is being used.

- [ ] **Step 6: Inspect generated OpenClaw config (optional)**

Stop a pool, check what PoolConfig generates:

```bash
# In iex:
instances = Druzhok.Repo.all(Druzhok.Instance) |> Enum.filter(& &1.pool_id == <pool_id>)
config = Druzhok.PoolConfig.build(instances)
IO.puts(Jason.encode!(config, pretty: true))
```

Verify the `tools.media.audio.models[0].model`, `tools.media.image.models[0].model`, and `agents.defaults.memorySearch.model` fields match the instance values.
