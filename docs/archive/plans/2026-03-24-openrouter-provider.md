# OpenRouter Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenRouter as a third LLM provider so users can select OpenRouter models in the dashboard and route LLM calls through `https://openrouter.ai/api/v1`.

**Architecture:** OpenRouter uses the OpenAI-compatible API, so routing goes through the existing `PiCore.LLM.OpenAI` client. The changes are: add "openrouter" to credential resolution (`Settings`), inject OpenRouter-required headers in the OpenAI client, add provider to dashboards (settings + models), and seed initial models.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/SQLite

**Spec:** `docs/superpowers/specs/2026-03-24-openrouter-multimodal-design.md` (Spec 1 section)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `v3/apps/druzhok/lib/druzhok/settings.ex:39-44` | Add "openrouter" arm to `api_url/1` |
| Modify | `v3/apps/pi_core/lib/pi_core/llm/openai.ex:10-25` | Inject OpenRouter headers |
| Modify | `v3/apps/druzhok/lib/druzhok/instance_manager.ex:227-230` | Add `provider_atom("openrouter")` |
| Modify | `v3/config/runtime.exs:86-91` | Add `OPENROUTER_API_KEY` env var |
| Modify | `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex` | Add OpenRouter fields |
| Modify | `v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex:227-228` | Add "openrouter" to dropdown |
| Create | `v3/apps/druzhok/priv/repo/migrations/20260324000004_seed_openrouter_models.exs` | Seed 3 models |
| Create | `v3/apps/druzhok/test/druzhok/settings_test.exs` | Test settings resolution |

---

### Task 1: Add OpenRouter to Settings credential resolution

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/settings.ex:39-44`
- Create: `v3/apps/druzhok/test/druzhok/settings_test.exs`

- [ ] **Step 1: Write failing test**

Create `v3/apps/druzhok/test/druzhok/settings_test.exs`:

```elixir
defmodule Druzhok.SettingsTest do
  use ExUnit.Case

  # Settings.api_url and api_key call Settings.get() which hits the Repo.
  # The Druzhok app (with Repo) is started in test via mix test in the umbrella.
  # get() returns nil for missing keys, so the || chain falls through to defaults.

  test "api_url returns openrouter URL for openrouter provider" do
    url = Druzhok.Settings.api_url("openrouter")
    assert url =~ "openrouter.ai"
  end

  test "api_url returns anthropic URL for anthropic provider" do
    url = Druzhok.Settings.api_url("anthropic")
    assert url =~ "anthropic.com"
  end

  test "api_url returns nebius URL for unknown provider" do
    url = Druzhok.Settings.api_url("nebius")
    assert url != nil
  end

  test "api_key resolves openrouter key from DB or env" do
    # With no DB entry and no env var, returns nil
    key = Druzhok.Settings.api_key("openrouter")
    # Just verify it doesn't crash — actual key comes from env/DB at runtime
    assert is_nil(key) or is_binary(key)
  end
end
```

**Note:** If the test crashes with "Repo not started", the test needs `use Druzhok.DataCase` or the umbrella test setup needs to start the app. Check `v3/apps/druzhok/test/test_helper.exs` — if it calls `Ecto.Adapters.SQL.Sandbox.mode(Druzhok.Repo, ...)`, use that pattern.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/settings_test.exs`

Expected: FAIL — "openrouter" falls through to the catch-all `_` and returns Nebius URL.

- [ ] **Step 3: Add "openrouter" arm to api_url/1**

In `v3/apps/druzhok/lib/druzhok/settings.ex`, replace the `api_url/1` function (lines 39-44):

```elixir
def api_url(provider) do
  case provider do
    "anthropic" -> get("anthropic_api_url") || Application.get_env(:pi_core, :anthropic_api_url) || "https://api.anthropic.com"
    "openrouter" -> get("openrouter_api_url") || Application.get_env(:pi_core, :openrouter_api_url) || "https://openrouter.ai/api/v1"
    _ -> get("nebius_api_url") || Application.get_env(:pi_core, :api_url)
  end
end
```

No change needed to `api_key/1` — it already uses dynamic key resolution via `get("#{provider}_api_key")`.

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/settings_test.exs`

Expected: All 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/apps/druzhok/lib/druzhok/settings.ex v3/apps/druzhok/test/druzhok/settings_test.exs
git commit -m "add openrouter to settings credential resolution"
```

---

### Task 2: Add OpenRouter env vars to runtime config

**Files:**
- Modify: `v3/config/runtime.exs:86-91`

- [ ] **Step 1: Add env vars**

In `v3/config/runtime.exs`, update the `config :pi_core` block (lines 86-91):

```elixir
config :pi_core,
  api_key: System.get_env("NEBIUS_API_KEY"),
  api_url:
    System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1",
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  anthropic_api_url: System.get_env("ANTHROPIC_API_URL") || "https://api.anthropic.com",
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  openrouter_api_url: System.get_env("OPENROUTER_API_URL") || "https://openrouter.ai/api/v1"
```

- [ ] **Step 2: Verify compilation**

Run: `cd v3 && mix compile`

Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/config/runtime.exs
git commit -m "add OPENROUTER_API_KEY env var to runtime config"
```

---

### Task 3: Inject OpenRouter headers in the OpenAI client

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/llm/openai.ex:10-25`
- Create: `v3/apps/pi_core/test/pi_core/llm/openai_test.exs`

- [ ] **Step 1: Write failing test**

Create `v3/apps/pi_core/test/pi_core/llm/openai_test.exs`:

```elixir
defmodule PiCore.LLM.OpenAITest do
  use ExUnit.Case

  test "build_request includes OpenRouter headers when provider is openrouter" do
    opts = %{
      model: "google/gemini-2.5-flash",
      provider: :openrouter,
      api_url: "https://openrouter.ai/api/v1",
      api_key: "test-key",
      system_prompt: "You are a test bot",
      messages: [],
      tools: [],
      max_tokens: 1024,
      stream: false
    }
    request = PiCore.LLM.OpenAI.build_request(opts)
    headers_map = Map.new(request.headers)
    assert headers_map["HTTP-Referer"] == "https://druzhok.app"
    assert headers_map["X-Title"] == "Druzhok"
  end

  test "build_request does not include OpenRouter headers for other providers" do
    opts = %{
      model: "some-model",
      provider: :openai,
      api_url: "https://api.nebius.com/v1",
      api_key: "test-key",
      system_prompt: "You are a test bot",
      messages: [],
      tools: [],
      max_tokens: 1024,
      stream: false
    }
    request = PiCore.LLM.OpenAI.build_request(opts)
    headers_map = Map.new(request.headers)
    assert headers_map["HTTP-Referer"] == nil
    assert headers_map["X-Title"] == nil
  end

  test "build_request works when provider key is absent" do
    opts = %{
      model: "some-model",
      api_url: "https://api.nebius.com/v1",
      api_key: "test-key",
      system_prompt: "You are a test bot",
      messages: [],
      tools: [],
      max_tokens: 1024,
      stream: false
    }
    request = PiCore.LLM.OpenAI.build_request(opts)
    headers_map = Map.new(request.headers)
    assert headers_map["HTTP-Referer"] == nil
    assert headers_map["authorization"] == "Bearer test-key"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/llm/openai_test.exs`

Expected: FAIL — no OpenRouter headers present.

- [ ] **Step 3: Add conditional headers in build_request**

In `v3/apps/pi_core/lib/pi_core/llm/openai.ex`, replace the `build_request/1` function (lines 10-25):

```elixir
def build_request(opts) do
  messages = [%{role: "system", content: opts.system_prompt} | opts.messages]

  body = %{model: opts.model, messages: messages, max_tokens: opts.max_tokens, stream: opts.stream}
  body = if opts.tools != [], do: Map.put(body, :tools, opts.tools), else: body

  headers = [
    {"content-type", "application/json"},
    {"authorization", "Bearer #{opts.api_key}"},
    {"accept-encoding", "identity"}
  ]

  headers = if opts[:provider] in [:openrouter, "openrouter"] do
    headers ++ [{"HTTP-Referer", "https://druzhok.app"}, {"X-Title", "Druzhok"}]
  else
    headers
  end

  %Request{
    url: "#{String.trim_trailing(opts.api_url, "/")}/chat/completions",
    headers: headers,
    body: Jason.encode!(body)
  }
end
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/llm/openai_test.exs`

Expected: Both tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/apps/pi_core/lib/pi_core/llm/openai.ex v3/apps/pi_core/test/pi_core/llm/openai_test.exs
git commit -m "inject OpenRouter headers in OpenAI client"
```

---

### Task 4: Add provider_atom for OpenRouter in instance manager

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance_manager.ex:227-230`

- [ ] **Step 1: Add provider_atom clause**

In `v3/apps/druzhok/lib/druzhok/instance_manager.ex`, add a new clause before the catch-all (after line 228):

```elixir
defp provider_atom("anthropic"), do: :anthropic
defp provider_atom("openai"), do: :openai
defp provider_atom("openrouter"), do: :openrouter
defp provider_atom(a) when is_atom(a), do: a
defp provider_atom(_), do: :openai
```

- [ ] **Step 2: Verify compilation**

Run: `cd v3 && mix compile`

Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/apps/druzhok/lib/druzhok/instance_manager.ex
git commit -m "add openrouter provider atom mapping"
```

---

### Task 5: Add OpenRouter to dashboard — Settings page

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Add assigns in mount**

In `settings_live.ex`, inside the `assign(socket, ...)` block in `mount/3` (after line 19), add:

```elixir
openrouter_api_key: mask(Druzhok.Settings.get("openrouter_api_key")),
openrouter_api_url: Druzhok.Settings.api_url("openrouter") || "",
```

- [ ] **Step 2: Add save handler**

In `handle_event("save", ...)`, after the anthropic block (after line 51), add:

```elixir
if val = non_masked(params["openrouter_api_key"]) do
  Druzhok.Settings.set("openrouter_api_key", val)
end
if val = non_empty(params["openrouter_api_url"]) do
  Druzhok.Settings.set("openrouter_api_url", val)
end
```

- [ ] **Step 3: Add re-assign after save**

In the `assign(socket, ...)` block inside `handle_event("save", ...)` (after line 73), add:

```elixir
openrouter_api_key: mask(Druzhok.Settings.get("openrouter_api_key")),
openrouter_api_url: Druzhok.Settings.api_url("openrouter") || "",
```

- [ ] **Step 4: Add UI section in render**

In the `render/1` function, after the Anthropic section (after line 132), add:

```heex
<div class="bg-white rounded-xl border border-gray-200 p-6">
  <h2 class="text-sm font-semibold mb-4">OpenRouter</h2>
  <div class="space-y-3">
    <div>
      <label class="block text-xs text-gray-500 mb-1">API Key</label>
      <input name="openrouter_api_key" value={@openrouter_api_key} placeholder="Paste new key to update"
             class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">API URL</label>
      <input name="openrouter_api_url" value={@openrouter_api_url}
             class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
    </div>
  </div>
</div>
```

- [ ] **Step 5: Verify compilation**

Run: `cd v3 && mix compile`

Expected: Compiles with no errors.

- [ ] **Step 6: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex
git commit -m "add OpenRouter fields to settings dashboard"
```

---

### Task 6: Add "openrouter" to models provider dropdown

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex:227-228`

- [ ] **Step 1: Add dropdown option**

In `v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex`, find the provider `<select>` (lines 227-228) and add the openrouter option:

```heex
<option value="openai" selected={@form_provider == "openai"}>openai</option>
<option value="anthropic" selected={@form_provider == "anthropic"}>anthropic</option>
<option value="openrouter" selected={@form_provider == "openrouter"}>openrouter</option>
```

- [ ] **Step 2: Verify compilation**

Run: `cd v3 && mix compile`

Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex
git commit -m "add openrouter to models provider dropdown"
```

---

### Task 7: Seed OpenRouter models via migration

**Files:**
- Create: `v3/apps/druzhok/priv/repo/migrations/20260324000004_seed_openrouter_models.exs`

- [ ] **Step 1: Create migration**

Create `v3/apps/druzhok/priv/repo/migrations/20260324000004_seed_openrouter_models.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.SeedOpenrouterModels do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO models (model_id, label, provider, context_window, supports_tools, supports_reasoning, position, inserted_at, updated_at) VALUES
      ('google/gemini-2.0-flash-lite-001', 'Gemini 2.0 Flash Lite', 'openrouter', 1048576, true, false, 20, datetime('now'), datetime('now')),
      ('google/gemini-2.5-flash-image', 'Gemini 2.5 Flash Image', 'openrouter', 1048576, false, false, 21, datetime('now'), datetime('now')),
      ('google/gemini-2.5-flash', 'Gemini 2.5 Flash', 'openrouter', 1048576, true, true, 22, datetime('now'), datetime('now'))
    """
  end

  def down do
    execute "DELETE FROM models WHERE provider = 'openrouter'"
  end
end
```

- [ ] **Step 2: Run migration**

Run: `cd v3 && mix ecto.migrate`

Expected: Migration runs successfully, 3 models inserted.

- [ ] **Step 3: Verify models exist**

Run: `cd v3 && mix run -e 'Druzhok.Repo.all(Druzhok.Model) |> Enum.filter(& &1.provider == "openrouter") |> Enum.each(& IO.puts(&1.model_id))'`

Expected: Prints 3 model IDs.

- [ ] **Step 4: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v3/apps/druzhok/priv/repo/migrations/20260324000004_seed_openrouter_models.exs
git commit -m "seed OpenRouter models (Gemini Flash Lite, Flash Image, Flash)"
```

---

### Task 8: Full test suite and final verification

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test`

Expected: All existing tests pass, no regressions.

- [ ] **Step 2: Manual verification (if OpenRouter API key available)**

Run:
```bash
cd v3 && mix run -e '
  result = PiCore.LLM.OpenAI.completion(%{
    model: "google/gemini-2.5-flash",
    provider: :openrouter,
    api_url: Druzhok.Settings.api_url("openrouter"),
    api_key: Druzhok.Settings.api_key("openrouter"),
    system_prompt: "Reply in one word.",
    messages: [%{role: "user", content: "Say hello"}],
    tools: [],
    max_tokens: 50,
    stream: false,
    on_delta: nil,
    on_event: nil
  })
  IO.inspect(result)
'
```

Expected: `{:ok, %Result{content: "Hello", ...}}` or similar.
