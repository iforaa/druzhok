# Hosted Translations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move hermes system-message translation data out of the Docker image into `druzhok/priv/translations.json`, injected into each bot on restart.

**Architecture:** Druzhok owns the translations JSON file in its `priv/` directory. `Druzhok.Runtime.Hermes.sync_config/2` writes a copy to `/opt/data/translations.json` inside each bot container on every start. A one-time hermes patch replaces the 157-line `gateway/translations.py` with a 25-line loader that reads the JSON at module-import time.

**Tech Stack:** Elixir/Phoenix (druzhok), Python (hermes), JSON (data format), Docker (hermes runtime).

**Spec:** `docs/superpowers/specs/2026-04-19-hosted-translations-design.md`

---

## File Structure

**Files created:**
- `v4/druzhok/apps/druzhok/priv/translations.json` — source of truth for translation data (ru only for now)

**Files modified:**
- `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` — add `sync_translations_file/1`, call from `sync_config/2`
- `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` — add `sync_config/2 — translations` describe block
- `~/.claude/skills/update-hermes/skill.md` — rewrite Customization #4 to inject the 25-line loader instead of the 157-line data file

**Files deleted:** none.

---

## Task 1: Seed `priv/translations.json`

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/translations.json`

- [ ] **Step 1: Create the translations JSON file**

Write this exact content to `v4/druzhok/apps/druzhok/priv/translations.json`:

```json
{
  "ru": {
    "✨ New session started!": "✨ Новая сессия!",
    "✨ Session reset! Starting fresh.": "✨ Сессия сброшена! Начинаем с чистого листа.",
    "Type /commands to see what's available, or resend without the leading slash to send as a regular message.": "Введи /commands чтобы увидеть доступные команды, или отправь без / как обычное сообщение.",
    "⚡ Stopped. You can continue this session.": "⚡ Остановлено. Можешь продолжить.",
    "No active task to stop.": "Нет активной задачи.",
    "Hi~ I don't recognize you yet!": "Привет! Я тебя пока не знаю!",
    "Here's your pairing code:": "Вот твой код подключения:",
    "Ask the bot owner to run:": "Попроси владельца бота выполнить:",
    "Too many pairing requests right now~ Please try again later!": "Слишком много запросов. Попробуй позже!",
    "No home channel is set for": "Домашний канал не настроен для",
    "A home channel is where Hermes delivers cron job results and cross-platform messages.": "Домашний канал — это чат для уведомлений, напоминаний и кросс-платформенных сообщений.",
    "Type /sethome to make this chat your home channel, or ignore to skip.": "Введи /sethome чтобы сделать этот чат домашним, или просто проигнорируй.",
    "Agent is running — wait or /stop first, then switch models.": "Агент работает — подожди или отправь /stop, потом переключай модель.",
    "No previous message to retry.": "Нет предыдущего сообщения для повтора.",
    "Nothing to undo.": "Нечего отменять.",
    "Not enough conversation to compress (need at least 4 messages).": "Недостаточно сообщений для сжатия (нужно минимум 4).",
    "No pending command to approve.": "Нет команды для одобрения.",
    "No pending command to deny.": "Нет команды для отклонения.",
    "Session too large for the model's context window.": "Сессия слишком большая для контекстного окна модели.",
    "Use /compact to compress the conversation, or /reset to start fresh.": "Используй /compact для сжатия разговора или /reset для нового начала.",
    "Voice mode enabled.": "Голосовой режим включён.",
    "Voice mode disabled. Text-only replies.": "Голосовой режим выключен. Только текст.",
    "No personalities configured": "Персоналити не настроены",
    "all commands auto-approved. Use with caution.": "все команды одобряются автоматически. Осторожно!",
    "Gateway restart already in progress...": "Перезапуск уже идёт...",
    "No usage data available for this session.": "Нет данных об использовании для этой сессии.",
    "No matching sessions found.": "Подходящие сессии не найдены.",
    "Memory is not available. It may be disabled in config or this environment.": "Память недоступна. Возможно, она отключена в настройках.",
    "Usage: /queue <prompt>": "Использование: /queue <запрос>",
    "Queued for the next turn.": "Добавлено в очередь.",
    "No commands available.": "Нет доступных команд.",
    "⚡ Force-stopped. The agent was still starting — session unlocked.": "⚡ Принудительно остановлено. Сессия разблокирована.",
    "⚡ Stopped. The agent hadn't started yet — you can continue this session.": "⚡ Остановлено. Можешь продолжить.",
    "Quick command timed out (30s).": "Быстрая команда не успела за 30 секунд.",
    "Command returned no output.": "Команда не вернула результат.",
    "⏳ Gateway restart already in progress...": "⏳ Перезапуск уже идёт...",
    "Failed to load the bundled /plan skill.": "Не удалось загрузить навык /plan.",
    "No conversation to branch — send a message first.": "Нет разговора для ветвления — сначала напиши сообщение.",
    "Session database not available.": "База данных сессий недоступна.",
    "Approval expired (agent is no longer waiting). Ask the agent to try again.": "Одобрение истекло (агент больше не ждёт). Попроси агента повторить.",
    "Unknown command": "Неизвестная команда"
  }
}
```

- [ ] **Step 2: Validate the JSON**

Run from repo root:

```bash
python3 -c "import json; print('keys:', len(json.load(open('v4/druzhok/apps/druzhok/priv/translations.json'))['ru']))"
```

Expected output: `keys: 41`

(The original `translations.py` has ~43 entries; some keys are duplicates or overlapping — the 41 above are the unique canonical set.)

- [ ] **Step 3: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/priv/translations.json
git commit -m "seed translations.json from hermes gateway/translations.py"
```

---

## Task 2: Add `sync_translations_file/1` helper with a failing test

**Files:**
- Modify: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` — add describe block at bottom (before closing `end`)
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` — add the helper (not called yet)

- [ ] **Step 1: Write the failing test**

Append this describe block to `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` **inside the outer module** (before the last `end` of the module). Check the existing structure — there's a `describe "sync_config/2 — group_sessions_per_user" do` block around line 153; add the new block just after `describe "sync_agents_md/2"`:

```elixir
  describe "sync_translations_file/1" do
    @tag :tmp_dir
    test "writes priv/translations.json verbatim to data_root", %{tmp_dir: tmp_dir} do
      assert :ok = Hermes.sync_translations_file(tmp_dir)

      dest = Path.join(tmp_dir, "translations.json")
      assert File.exists?(dest)

      content = File.read!(dest)
      decoded = Jason.decode!(content)
      assert is_map(decoded["ru"])
      assert decoded["ru"]["✨ New session started!"] == "✨ Новая сессия!"
    end

    @tag :tmp_dir
    test "overwrites an existing translations.json on every call", %{tmp_dir: tmp_dir} do
      stale = Path.join(tmp_dir, "translations.json")
      File.write!(stale, ~s({"ru":{"old":"stale"}}))

      assert :ok = Hermes.sync_translations_file(tmp_dir)

      decoded = File.read!(stale) |> Jason.decode!()
      refute Map.has_key?(decoded["ru"], "old")
      assert decoded["ru"]["✨ New session started!"] == "✨ Новая сессия!"
    end
  end
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs --only tmp_dir
```

Expected: **2 failures** with `UndefinedFunctionError: function Druzhok.Runtime.Hermes.sync_translations_file/1 is undefined` or similar.

- [ ] **Step 3: Implement the helper**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, add this public function. Place it near the other `sync_*` helpers (e.g., right after `sync_agents_md/2`):

```elixir
  @doc """
  Write priv/translations.json into data_root so hermes's patched
  gateway/translations.py can load it at import time.

  Called from sync_config/2 on every bot start — overwriting with the
  same content is harmless and keeps edits in druzhok's priv/ propagating
  to all bots on restart without an image rebuild.
  """
  def sync_translations_file(data_root) do
    require Logger
    priv_path = Path.join(:code.priv_dir(:druzhok), "translations.json")
    dest = Path.join(data_root, "translations.json")

    case File.read(priv_path) do
      {:ok, content} ->
        File.write!(dest, content)
        :ok

      {:error, reason} ->
        Logger.warning("sync_translations_file: cannot read #{priv_path}: #{inspect(reason)}")
        :ok
    end
  end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests in the file pass, including the 2 new ones.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs
git commit -m "hermes runtime: add sync_translations_file helper"
```

---

## Task 3: Wire `sync_translations_file` into `sync_config/2`

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` — call the helper from `sync_config/2`
- Modify: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` — add describe block verifying `sync_config/2` writes translations

- [ ] **Step 1: Write the failing test**

Append this describe block to `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` (same location as Task 2, after the `sync_translations_file/1` describe):

```elixir
  describe "sync_config/2 — translations injection" do
    @tag :tmp_dir
    test "writes translations.json alongside config.yaml", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")

      assert :ok = Hermes.sync_config(@instance, tmp_dir)

      translations_path = Path.join(tmp_dir, "translations.json")
      assert File.exists?(translations_path)

      decoded = File.read!(translations_path) |> Jason.decode!()
      assert decoded["ru"]["✨ New session started!"] == "✨ Новая сессия!"
    end
  end
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs -t tmp_dir
```

Expected: the new test fails with `File.exists?(translations_path)` evaluating to `false` (because `sync_config/2` does not yet call `sync_translations_file/1`).

- [ ] **Step 3: Update `sync_config/2` to call the helper**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, find the `sync_config/2` function (around line 132). Add a call to `sync_translations_file/1` right after `sync_agents_md(instance, data_root)`:

```elixir
  @impl true
  def sync_config(instance, data_root) do
    sync_agents_md(instance, data_root)
    sync_translations_file(data_root)

    # Patch dashboard-owned fields in config.yaml on every start so the
    # dashboard stays the source of truth without clobbering hermes's
    # runtime writes (thread IDs etc).
    config_path = Path.join(data_root, "config.yaml")
    model = Map.get(instance, :model) || @default_model
    vision_model = Map.get(instance, :image_model) || @default_vision_model
    tenant_key = Map.get(instance, :tenant_key, "") || ""

    case File.read(config_path) do
      {:ok, content} ->
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
          |> sync_memory_enabled()

        if updated != content, do: File.write!(config_path, updated)
        :ok

      {:error, _} ->
        :ok
    end
  end
```

(Only the `sync_translations_file(data_root)` line is new — the rest of the function is unchanged. Preserve the exact existing indentation and formatting.)

- [ ] **Step 4: Run the test to confirm it passes**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs
git commit -m "hermes runtime: inject translations.json via sync_config"
```

---

## Task 4: Rewrite the hermes `translations.py` patch in `update-hermes` skill

**Files:**
- Modify: `~/.claude/skills/update-hermes/skill.md` — replace the Customization #4 body

- [ ] **Step 1: Read the current Customization #4 block**

```bash
grep -n "Customization 4" ~/.claude/skills/update-hermes/skill.md
```

Then read that section (~50 lines around line 237) to understand the current text. The existing block ships the full 157-line `translations.py` with an embedded dict.

- [ ] **Step 2: Replace the "what to write" content**

In `~/.claude/skills/update-hermes/skill.md`, find the heading `### Customization 4: System message translation` and the sub-step `(A) Create gateway/translations.py with the translation dict`.

Replace sub-step (A)'s description with this exact text:

```markdown
(A) Create `gateway/translations.py` as a lightweight JSON loader (not an embedded dict). Content:

```python
"""Druzhok downstream: system message translations loaded from JSON.

Reads translations from /opt/data/translations.json at module-import
time. The JSON file is written by druzhok's Hermes runtime adapter
(sync_translations_file/1) on every bot start — edit translations in
druzhok/priv/translations.json, not here.

If the JSON file is missing or malformed, _TRANSLATIONS is empty and
all messages fall back to English.
"""

import json
import os

_TRANSLATIONS_PATH = os.getenv(
    "HERMES_TRANSLATIONS_PATH",
    "/opt/data/translations.json",
)

try:
    with open(_TRANSLATIONS_PATH, encoding="utf-8") as _f:
        _TRANSLATIONS = json.load(_f)
except (FileNotFoundError, json.JSONDecodeError):
    _TRANSLATIONS = {}


def translate_system_message(text: str) -> str:
    """Translate a hermes system message if a translation exists.

    Uses HERMES_LANGUAGE env var. Returns the original text if no
    translation is found or language is English.
    """
    if not text:
        return text

    lang = os.getenv("HERMES_LANGUAGE", "en").lower()
    if lang == "en":
        return text

    translations = _TRANSLATIONS.get(lang)
    if not translations:
        return text

    if text in translations:
        return translations[text]

    result = text
    for en_phrase, translated in translations.items():
        if en_phrase in result:
            result = result.replace(en_phrase, translated)

    return result
```

The translation data lives in `v4/druzhok/apps/druzhok/priv/translations.json` and is injected into the container at `/opt/data/translations.json` by druzhok's `sync_config/2`. Do not put translation data in this file — just the loader and function.
```

(Leave sub-steps B and C — the two `run.py` call-site additions — unchanged. They import `translate_system_message` and remain identical.)

- [ ] **Step 3: Update the syntax-check note**

Find the line at ~272 that says:

```
python3 -c "import ast; ast.parse(open('gateway/translations.py').read())"
```

This stays identical — the new file is valid Python and the syntax check still applies.

- [ ] **Step 4: Commit the skill change**

```bash
cd ~/.claude/skills/update-hermes
git add skill.md 2>/dev/null || true
# If the skills dir is not a git repo, just save — no commit needed.
```

(The `.claude/skills/` directory may or may not be under git. If it is, commit; if not, the edit persists on disk.)

---

## Task 5: Rebuild and deploy hermes image, then restart druzhok

**Files:** none (deployment only).

This is a one-time image rebuild. After this, translations edits never touch the image.

- [ ] **Step 1: Push the druzhok code changes**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git push origin main
```

- [ ] **Step 2: Invoke the `update-hermes` skill**

Use the skill system:

```
/update-hermes
```

The skill will:
1. Pull latest hermes upstream.
2. Re-apply all 5 customizations (including the now-shortened #4).
3. Build the image for `linux/amd64`.
4. Transfer + load on the remote.
5. Restart all bot containers.

Expected end state: the remote `hermes:latest` image has the new 25-line `gateway/translations.py` loader, and all bot containers are running against it.

- [ ] **Step 3: Deploy druzhok side**

```bash
ssh -l igor 158.160.78.230 'cd ~/druzhok && git pull && source ~/.bashrc; . ~/.asdf/asdf.sh; cd v4/druzhok && mix compile 2>&1 | tail -5 && sudo systemctl restart druzhok && sleep 3 && systemctl is-active druzhok'
```

Expected: `active`.

- [ ] **Step 4: Verify the JSON file is in every bot's data root**

```bash
ssh -l igor 158.160.78.230 'for dir in /home/igor/druzhok-data/v4-instances/*/; do name=$(basename "$dir"); echo "=== $name ==="; if [ -f "$dir/translations.json" ]; then head -c 80 "$dir/translations.json"; echo; else echo "MISSING"; fi; done'
```

Expected: each bot's directory contains a `translations.json` starting with `{"ru":{"✨ New session started!":"✨ Новая сессия!"...`.

- [ ] **Step 5: Smoke-test a bot**

In Telegram, send `/new` to `@igorhermes`. Expected reply (the exact current translation):

```
✨ Сессия сброшена! Начинаем с чистого листа.

◆ Model: xiaomi/mimo-v2-pro
...
```

If the reply is in English, translations failed to load — check:
1. `docker exec druzhok-bot-igorhermes cat /opt/data/translations.json | head -c 100` — is the file present?
2. `docker exec druzhok-bot-igorhermes cat /opt/hermes/gateway/translations.py` — is it the new 25-line version?
3. `docker exec druzhok-bot-igorhermes env | grep HERMES_LANGUAGE` — is it `ru`?

---

## Task 6: End-to-end test the hot-edit flow

**Files:** none (validation).

Prove that a translation edit now takes effect without rebuilding the image.

- [ ] **Step 1: Edit one translation locally**

In `v4/druzhok/apps/druzhok/priv/translations.json`, change one value. For example:

```json
"✨ Session reset! Starting fresh.": "✨ Сессия ПЕРЕЗАПУЩЕНА! Начинаем с чистого листа."
```

(Capital "ПЕРЕЗАПУЩЕНА" makes it easy to spot in a reply.)

- [ ] **Step 2: Commit and deploy**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/priv/translations.json
git commit -m "test: tweak session reset translation for hot-edit verification"
git push origin main

ssh -l igor 158.160.78.230 'cd ~/druzhok && git pull && sudo systemctl restart druzhok && sleep 3 && systemctl is-active druzhok'
```

- [ ] **Step 3: Send `/new` to the bot and verify**

Expected reply contains "ПЕРЕЗАПУЩЕНА" — proves the new translation loaded without rebuilding the image.

- [ ] **Step 4: Revert the test edit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
# Edit priv/translations.json back to the original "✨ Сессия сброшена! Начинаем с чистого листа."
git add v4/druzhok/apps/druzhok/priv/translations.json
git commit -m "revert test translation tweak"
git push origin main
ssh -l igor 158.160.78.230 'cd ~/druzhok && git pull && sudo systemctl restart druzhok'
```

---

## Self-Review Notes

- **Spec coverage:** every component in the spec is mapped — seed file (Task 1), `sync_translations_file/1` helper (Task 2), wiring into `sync_config/2` (Task 3), hermes patch (Task 4), migration (Task 5), smoke test (Task 6).
- **Out-of-scope items from the spec** (multi-language, per-bot overrides, dashboard UI, hot-reload without restart) are not in any task — correct.
- **Method names:** `sync_translations_file/1` is used consistently across Tasks 2, 3, and the spec.
- **No placeholders:** every step has concrete commands, file paths, and code.
