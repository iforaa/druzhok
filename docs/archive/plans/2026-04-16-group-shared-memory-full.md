# Shared Group Memory (Full) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a per-instance `group_shared_memory` boolean that, when enabled, strips `message_thread_id` from Telegram group messages and records untriggered group messages into the session transcript, so the bot has unified context across reply-chains and silent chatter.

**Architecture:** Two small additive patches to `gateway/platforms/telegram.py` downstream of hermes (no upstream PR). A single config key `group_shared_memory` gates both patches. Druzhok exposes the key as an `instances` column, writes it into generated `config.yaml` via `sync_config`, and surfaces a dashboard checkbox. The `update-hermes` skill gains two Customization sections so the patches re-apply automatically on every upstream pull.

**Tech Stack:** Elixir/Phoenix LiveView/Ecto/SQLite (druzhok), Python/python-telegram-bot (hermes-agent), Markdown (update-hermes skill).

**Spec:** `docs/superpowers/specs/2026-04-16-group-shared-memory-full-design.md`

---

## File Structure

**Create:**
- `v4/druzhok/apps/druzhok/priv/repo/migrations/20260416000001_add_group_shared_memory_to_instances.exs` — adds the boolean column.

**Modify (druzhok):**
- `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex` — add field + cast (one line each near lines 37, 45).
- `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` — emit key in `build_config_yaml/1` and patch via new helper `sync_group_shared_memory/2` wired into `sync_config/2` pipeline.
- `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` — tests for both emission paths.
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — new checkbox + event handler under Group Chats.

**Modify (hermes-agent — local downstream patch):**
- `v4/hermes-agent/gateway/platforms/telegram.py` — 3-line insertion in `_build_message_event`, 3-line insertion in `_handle_text_message`, new `_record_passive_group_message` helper at end of the `TelegramAdapter` class.

**Modify (update-hermes skill):**
- `~/.claude/skills/update-hermes/SKILL.md` — add Customization 3 and Customization 4 sections, replacing the "(Future customizations)" placeholder.

**No changes to:**
- `gateway/session.py` — existing `get_or_create_session` and `append_to_transcript` APIs are used as-is.
- Non-telegram platform adapters — patches are telegram-only.
- DM code paths — no behaviour change.

---

## Task 1: Druzhok migration

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260416000001_add_group_shared_memory_to_instances.exs`

- [ ] **Step 1: Write the migration file**

```elixir
defmodule Druzhok.Repo.Migrations.AddGroupSharedMemoryToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :group_shared_memory, :boolean, default: false, null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration against the dev DB**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
DATABASE_PATH=data/druzhok.db mix ecto.migrate
```

Expected: `[info] == Running 20260416000001 ...` followed by `[info] == Migrated in Nms`. No errors.

- [ ] **Step 3: Verify column exists**

```bash
sqlite3 /Users/igorkuznetsov/Documents/druzhok/v4/druzhok/data/druzhok.db "PRAGMA table_info(instances);" | grep group_shared_memory
```

Expected: one line showing the column with `INTEGER` type (SQLite's boolean storage), `NOT NULL`, default `0`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/priv/repo/migrations/20260416000001_add_group_shared_memory_to_instances.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "migration: add group_shared_memory to instances (default false)"
```

---

## Task 2: Druzhok schema field + cast

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex` at lines ~37 (field) and ~45 (cast list)

- [ ] **Step 1: Add the schema field**

In `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`, right after the existing line:

```elixir
    field :group_sessions_per_user, :boolean, default: true
```

add:

```elixir
    field :group_shared_memory, :boolean, default: false
```

- [ ] **Step 2: Add the field to the cast whitelist**

In the `changeset/2` function's `cast/3` call, append `:group_shared_memory` to the end of the list. The final list should end `..., :dreaming, :group_sessions_per_user, :group_shared_memory])`.

- [ ] **Step 3: Compile — catch typos**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix compile --warnings-as-errors
```

Expected: compiles clean (ignore pre-existing `Bcrypt` warnings in `druzhok` app).

- [ ] **Step 4: Smoke-test the changeset**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`, create `/tmp/smoketest.exs`:

```elixir
cs = Druzhok.Instance.changeset(%Druzhok.Instance{}, %{name: "t", model: "m", workspace: "w", group_shared_memory: true})
IO.inspect(cs.valid?, label: "valid?")
IO.inspect(Ecto.Changeset.get_change(cs, :group_shared_memory), label: "value")
```

Run: `DATABASE_PATH=data/druzhok.db mix run /tmp/smoketest.exs`

Expected stdout:
```
valid?: true
value: true
```

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/instance.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "schema: add group_shared_memory field + cast"
```

---

## Task 3: Druzhok — emit key in `build_config_yaml/1` (seed)

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` (`build_config_yaml/1` body)
- Test: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`

- [ ] **Step 1: Write the failing tests**

In `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`, append a new `describe` block before the final `end`:

```elixir
  describe "build_config_yaml/1 — group_shared_memory" do
    test "emits group_shared_memory: true when set" do
      inst = Map.put(@instance, :group_shared_memory, true)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_shared_memory: true$/m
    end

    test "emits group_shared_memory: false when set" do
      inst = Map.put(@instance, :group_shared_memory, false)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_shared_memory: false$/m
    end

    test "defaults to false when key missing on the instance map" do
      inst = Map.delete(@instance, :group_shared_memory)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_shared_memory: false$/m
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: 3 new failures — yaml doesn't contain the key yet.

- [ ] **Step 3: Emit the key inside the heredoc**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, inside `build_config_yaml/1`, below the existing line:

```elixir
    group_sessions_per_user = Map.get(instance, :group_sessions_per_user, true)
```

add:

```elixir
    group_shared_memory = Map.get(instance, :group_shared_memory, false)
```

Then in the heredoc body, immediately after the existing line `group_sessions_per_user: #{group_sessions_per_user}`, add:

```
    group_shared_memory: #{group_shared_memory}
```

(Note: the heredoc uses leading 4-space indentation within the triple-quoted string but the emitted lines themselves are at column 0 of the yaml. Match the existing `group_sessions_per_user:` line's formatting exactly.)

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass, including the 3 new ones.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "hermes: seed group_shared_memory into generated config.yaml"
```

---

## Task 4: Druzhok — patch key in `sync_config/2`

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` (`sync_config/2` pipeline + new helper)
- Test: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`

Why: existing bots have `config.yaml` files that pre-date this feature. `sync_config` runs on every container start and is already the mechanism for keeping dashboard-owned keys authoritative.

- [ ] **Step 1: Write the failing tests**

Append another `describe` block in `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`:

```elixir
  describe "sync_config/2 — group_shared_memory" do
    @tag :tmp_dir
    test "appends the key when absent", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")

      inst = Map.put(@instance, :group_shared_memory, true)
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert yaml =~ ~r/^group_shared_memory: true$/m
    end

    @tag :tmp_dir
    test "overwrites an existing value rather than duplicating", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"

      group_shared_memory: false
      """)

      inst = Map.put(@instance, :group_shared_memory, true)
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      matches = Regex.scan(~r/^group_shared_memory:/m, yaml)
      assert length(matches) == 1
      assert yaml =~ ~r/^group_shared_memory: true$/m
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: 2 new failures.

- [ ] **Step 3: Add the helper function**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, right after the existing `sync_group_sessions_per_user/2` helper, add:

```elixir
  defp sync_group_shared_memory(content, instance) do
    value = Map.get(instance, :group_shared_memory, false)
    line = "group_shared_memory: #{value}"

    if Regex.match?(~r/^group_shared_memory:.*$/m, content) do
      Regex.replace(~r/^group_shared_memory:.*$/m, content, line)
    else
      String.trim_trailing(content) <> "\n\n" <> line <> "\n"
    end
  end
```

- [ ] **Step 4: Wire the helper into `sync_config/2`**

In `sync_config/2`, append to the existing pipeline. Change:

```elixir
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
```

to:

```elixir
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
          |> sync_group_shared_memory(instance)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass (existing + 3 from Task 3 + 2 new ones).

- [ ] **Step 6: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "hermes: patch group_shared_memory in sync_config on every start"
```

---

## Task 5: Druzhok — UI toggle in `settings_tab`

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — new checkbox in Group Chats section, new event handler

- [ ] **Step 1: Add the checkbox to the template**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex`, find the Group Chats section and the existing "Shared group memory" checkbox (added in the previous project). Immediately after its closing `</label>`, insert a new label:

```heex
        <label class="flex items-center gap-3 cursor-pointer select-none mt-3">
          <input type="checkbox" phx-click="toggle_group_shared_memory" phx-target={@myself}
                 phx-throttle="1000"
                 checked={@instance[:group_shared_memory]}
                 class="w-4 h-4 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0" />
          <span class="text-sm text-fg">Record all group messages — bot reads everything, answers only when addressed</span>
        </label>
```

Semantic note: this toggle's DB column (`group_shared_memory`) is a "positive" flag — `true` means the feature is on, which matches UI intuition. No inversion (unlike `group_sessions_per_user` where DB true means "off" from the user's perspective).

- [ ] **Step 2: Add the event handler**

In the same file, after the existing `toggle_group_sessions_per_user` event handler, insert:

```elixir
  def handle_event("toggle_group_shared_memory", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:group_shared_memory]
    update_instance(name, %{group_shared_memory: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end
```

- [ ] **Step 3: Compile and run tests**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix compile --warnings-as-errors
```

Then:

```bash
mix test
```

Expected: compiles clean; Druzhok tests pass (the druzhok_web 7 pre-existing failures from earlier are not introduced by this task — confirm by checking that none of the 7 are about `group_shared_memory`).

- [ ] **Step 4: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "dashboard: add record-all-group-messages toggle"
```

---

## Task 6: Hermes patch — strip `thread_id` for group chats

**Files:**
- Modify: `v4/hermes-agent/gateway/platforms/telegram.py` — `_build_message_event` body

Note: hermes-agent is pulled from upstream; our Dockerfile and gateway/run.py already have downstream modifications. This task adds a third local modification. We do NOT commit this to the hermes-agent repo (it's tracked as a local working-tree diff that the `update-hermes` skill re-applies). Do commit it to the druzhok parent repo if the hermes-agent dir is vendored in-tree there.

Check first: verify `v4/hermes-agent` is part of the druzhok root git repo (not a nested submodule). Run from the druzhok root:

```bash
git -C /Users/igorkuznetsov/Documents/druzhok status v4/hermes-agent/gateway/platforms/telegram.py
```

If it shows as tracked, we commit changes to that file in the parent repo. If it shows as a submodule or untracked, treat it as a working-tree-only modification (don't commit).

- [ ] **Step 1: Add the patch in `_build_message_event`**

In `v4/hermes-agent/gateway/platforms/telegram.py`, find the line `source = self.build_source(` inside `_build_message_event`. Right before that call, insert:

```python
        # Druzhok patch: when group_shared_memory is on, collapse Telegram
        # reply-chain message_thread_id values for group chats so all
        # messages land in one session per group.
        effective_thread_id = thread_id_str
        if chat_type == "group" and self.config.extra.get("group_shared_memory", False):
            effective_thread_id = None
```

Then change the `thread_id=thread_id_str,` line inside the `build_source(...)` call to:

```python
            thread_id=effective_thread_id,
```

- [ ] **Step 2: Syntax-check**

```bash
python3 -c "import ast; ast.parse(open('/Users/igorkuznetsov/Documents/druzhok/v4/hermes-agent/gateway/platforms/telegram.py').read())"
```

Expected: no output (parses clean).

- [ ] **Step 3: Verify the patch is in place**

```bash
grep -c "group_shared_memory" /Users/igorkuznetsov/Documents/druzhok/v4/hermes-agent/gateway/platforms/telegram.py
```

Expected: `1` (this task adds one reference; Task 7 adds two more).

- [ ] **Step 4: Commit (if tracked in parent repo)**

If the file is tracked:

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/hermes-agent/gateway/platforms/telegram.py
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "hermes patch: strip thread_id for group chats when group_shared_memory=true"
```

If untracked, skip commit — the `update-hermes` skill will regenerate the change.

---

## Task 7: Hermes patch — silent observer for groups

**Files:**
- Modify: `v4/hermes-agent/gateway/platforms/telegram.py` — `_handle_text_message` early-return and new helper

- [ ] **Step 1: Add the passive-record hook to `_handle_text_message`**

Find the `_handle_text_message` method (around line 2156). The current body is:

```python
    async def _handle_text_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        """..."""
        if not update.message or not update.message.text:
            return
        if not self._should_process_message(update.message):
            return

        event = self._build_message_event(update.message, MessageType.TEXT)
        event.text = self._clean_bot_trigger_text(event.text)
        self._enqueue_text_event(event)
```

Change the inner `if not self._should_process_message(update.message): return` block to:

```python
        if not self._should_process_message(update.message):
            # Druzhok patch: silent observer for group chats — record the
            # message into the session transcript so the bot has context
            # when it IS later addressed. Agent loop is not invoked.
            if self._is_group_chat(update.message) and self.config.extra.get("group_shared_memory", False):
                await self._record_passive_group_message(update.message)
            return
```

- [ ] **Step 2: Add the helper method at the end of the `TelegramAdapter` class**

Find the last method in the `TelegramAdapter` class. Scroll to the `class` block's closing — typically the file ends with a final method followed by module-level code (or EOF). Immediately before the end of the class (before any module-level code that follows), add:

```python
    async def _record_passive_group_message(self, message) -> None:
        """Record an untriggered group message as passive context.

        Builds a MessageEvent as if the bot were going to process the
        message, then appends a ``role: "user"`` entry to the session
        transcript without invoking the agent loop. Prefixes the text
        with the sender's display name so the model can attribute it.
        """
        try:
            event = self._build_message_event(message, MessageType.TEXT)
            if not event.text:
                return
            user_label = event.source.user_name or event.source.user_id or "user"
            content = f"{user_label}: {event.text}"

            session_entry = self._session_store.get_or_create_session(event.source)
            self._session_store.append_to_transcript(
                session_entry.session_id,
                {"role": "user", "content": content},
            )
        except Exception as exc:
            logger.debug("[%s] Passive record failed: %s", self.name, exc)
```

Notes:
- `self._session_store` is populated by `set_session_store` in `base.py:932`; safe to use from any handler.
- `get_or_create_session(source)` returns a `SessionEntry` (see `session.py:682`).
- `append_to_transcript(session_id, message)` writes to both SQLite and legacy JSONL (see `session.py:947`).
- The broad `except` is intentional — never let a passive-record failure crash regular message handling.

- [ ] **Step 3: Syntax-check**

```bash
python3 -c "import ast; ast.parse(open('/Users/igorkuznetsov/Documents/druzhok/v4/hermes-agent/gateway/platforms/telegram.py').read())"
```

Expected: no output.

- [ ] **Step 4: Verify patches are in place**

```bash
grep -c "group_shared_memory" /Users/igorkuznetsov/Documents/druzhok/v4/hermes-agent/gateway/platforms/telegram.py
```

Expected: `2` (Task 6 added one, Task 7 adds one more in the `_handle_text_message` hook).

```bash
grep -c "_record_passive_group_message" /Users/igorkuznetsov/Documents/druzhok/v4/hermes-agent/gateway/platforms/telegram.py
```

Expected: `2` (one call site, one definition).

- [ ] **Step 5: Commit (if tracked in parent repo)**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/hermes-agent/gateway/platforms/telegram.py
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "hermes patch: silent observer for group chats"
```

---

## Task 8: Update the `update-hermes` skill

**Files:**
- Modify: `/Users/igorkuznetsov/.claude/skills/update-hermes/SKILL.md`

- [ ] **Step 1: Replace the "(Future customizations)" placeholder with two real sections**

Find the existing section in `/Users/igorkuznetsov/.claude/skills/update-hermes/SKILL.md`:

```markdown
### Customization 2: (Future customizations)

Add new sections as needed. Each section must have:
- **Intent:** what the customization achieves (business logic, not code)
- **Where:** which file and method to look in
- **How to find it:** search pattern that works even if line numbers change
- **Apply:** the concrete code change
- **Verify:** how to confirm it was applied correctly
- **Skip condition:** what to look for that means hermes added native support
```

Replace that block with:

```markdown
### Customization 2: Strip thread_id for group chats (`gateway/platforms/telegram.py`)

**Intent:** When `group_shared_memory: true` in `config.yaml`, make all Telegram group-chat messages share one session regardless of `message_thread_id`. Without this, Telegram's automatic reply-chain thread ids split group conversations into many sessions and the bot loses context across chains. Gated on config key so the behaviour is opt-in per instance.

**Where:** In `gateway/platforms/telegram.py`, method `_build_message_event`.

**How to find it:** Search for `def _build_message_event`. Locate the call `source = self.build_source(` inside that method. The call passes `thread_id=thread_id_str`; the patch goes right before the call.

**Apply:**

Insert before the `self.build_source(...)` call:

```python
# Druzhok patch: when group_shared_memory is on, collapse Telegram
# reply-chain message_thread_id values for group chats so all
# messages land in one session per group.
effective_thread_id = thread_id_str
if chat_type == "group" and self.config.extra.get("group_shared_memory", False):
    effective_thread_id = None
```

And change `thread_id=thread_id_str,` inside the `self.build_source(...)` call to `thread_id=effective_thread_id,`.

**Verify:**

```bash
python3 -c "import ast; ast.parse(open('gateway/platforms/telegram.py').read())"
grep -c 'group_shared_memory' gateway/platforms/telegram.py  # expect >= 1
grep -c 'effective_thread_id' gateway/platforms/telegram.py  # expect 2 (assignment + usage)
```

**Skip condition:** If upstream adds a native `collapse_threads`, `group_shared_session`, or similar config key that achieves the same, drop this customization and tell the user.

### Customization 3: Silent observer for group chats (`gateway/platforms/telegram.py`)

**Intent:** When `group_shared_memory: true`, record untriggered group-chat messages into the session transcript so the bot has conversational context when later addressed. Agent loop stays idle; only the transcript grows. Pairs with Customization 2.

**Where:** In `gateway/platforms/telegram.py`, two changes:
1. Inside `_handle_text_message`, at the existing early return `if not self._should_process_message(update.message): return`.
2. A new method `_record_passive_group_message` added at the end of the `TelegramAdapter` class (so it stays out of the churn zone).

**How to find it:** Search for `async def _handle_text_message`. The body contains two successive early returns; the second one (`if not self._should_process_message...`) is where we hook in. For the helper placement, find the last `async def` inside `class TelegramAdapter` and add the new helper immediately after it.

**Apply:**

Change the second early return from:

```python
if not self._should_process_message(update.message):
    return
```

to:

```python
if not self._should_process_message(update.message):
    # Druzhok patch: silent observer for group chats — record the
    # message into the session transcript so the bot has context
    # when it IS later addressed. Agent loop is not invoked.
    if self._is_group_chat(update.message) and self.config.extra.get("group_shared_memory", False):
        await self._record_passive_group_message(update.message)
    return
```

Add a new helper method at the end of the `TelegramAdapter` class:

```python
async def _record_passive_group_message(self, message) -> None:
    """Record an untriggered group message as passive context.

    Builds a MessageEvent as if the bot were going to process the
    message, then appends a ``role: "user"`` entry to the session
    transcript without invoking the agent loop. Prefixes the text
    with the sender's display name so the model can attribute it.
    """
    try:
        event = self._build_message_event(message, MessageType.TEXT)
        if not event.text:
            return
        user_label = event.source.user_name or event.source.user_id or "user"
        content = f"{user_label}: {event.text}"

        session_entry = self._session_store.get_or_create_session(event.source)
        self._session_store.append_to_transcript(
            session_entry.session_id,
            {"role": "user", "content": content},
        )
    except Exception as exc:
        logger.debug("[%s] Passive record failed: %s", self.name, exc)
```

**Verify:**

```bash
python3 -c "import ast; ast.parse(open('gateway/platforms/telegram.py').read())"
grep -c '_record_passive_group_message' gateway/platforms/telegram.py  # expect 2 (call + def)
grep -c 'group_shared_memory' gateway/platforms/telegram.py  # expect >= 2 (Cust 2 + this)
```

**Skip condition:** If upstream adds a native "listen-only" / "silent observer" mode that achieves the same, drop this customization.

### Customizations 2 and 3 are paired

Both are gated on the same config key `group_shared_memory`. Always apply them together — applying one without the other produces a broken configuration. Users who want just thread collapsing OR just silent observing should file it as a separate request.

### Customization 4: (Future customizations)

Add new sections as needed. Each section must have:
- **Intent:** what the customization achieves (business logic, not code)
- **Where:** which file and method to look in
- **How to find it:** search pattern that works even if line numbers change
- **Apply:** the concrete code change
- **Verify:** how to confirm it was applied correctly
- **Skip condition:** what to look for that means hermes added native support
```

- [ ] **Step 2: Sanity-check the skill file**

```bash
head -5 /Users/igorkuznetsov/.claude/skills/update-hermes/SKILL.md
grep -c "^### Customization" /Users/igorkuznetsov/.claude/skills/update-hermes/SKILL.md
```

Expected: YAML frontmatter still intact, and the customization count is now 4 (Customization 1, 2, 3, and the empty "Customization 4: (Future customizations)" placeholder).

- [ ] **Step 3: Commit**

The skill lives in `~/.claude/skills/update-hermes/` which is typically outside the druzhok repo. Check first:

```bash
git -C /Users/igorkuznetsov/.claude/skills/update-hermes rev-parse --git-dir 2>/dev/null && echo "in git" || echo "not in git"
```

If in git, commit there:

```bash
git -C /Users/igorkuznetsov/.claude/skills/update-hermes add SKILL.md
git -C /Users/igorkuznetsov/.claude/skills/update-hermes commit -m "update-hermes: add group_shared_memory patches"
```

If not in git, skip commit — the file is personal config and doesn't need versioning.

---

## Task 9: Production deploy

This task is operational, not code. All prior tasks must be committed and pushed to origin/main before starting.

- [ ] **Step 1: Push local commits**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok push origin main
```

Expected: push succeeds.

- [ ] **Step 2: Pull code on the remote**

```bash
ssh igor@158.160.78.230 "cd ~/druzhok && git pull 2>&1 | tail -5"
```

Expected: fast-forward pulling the new commits.

- [ ] **Step 3: Rebuild hermes image**

The hermes patches (Tasks 6 and 7) require a new Docker image. Check if the remote builds the image directly or fetches from a registry. For this project, rebuild on the remote:

```bash
ssh igor@158.160.78.230 "cd ~/druzhok/v4/hermes-agent && docker buildx build --platform linux/amd64 --build-arg OPENCLAW_VARIANT=slim --build-arg 'OPENCLAW_EXTENSIONS=telegram openai' --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 --build-arg 'OPENCLAW_DOCKER_APT_PACKAGES=python3 wkhtmltopdf ffmpeg' -t hermes:latest --load ." 2>&1 | tail -5
```

If remote build is too slow or lacks disk, fall back to the local-build-then-stream approach from `update-hermes` skill Step 2 + Step 4.

Wait for the build to complete before proceeding. Expected: `=> => naming to docker.io/library/hermes:latest`.

- [ ] **Step 4: Run the migration on production DB**

```bash
ssh igor@158.160.78.230 "source ~/.bashrc; . ~/.asdf/asdf.sh; cd ~/druzhok/v4/druzhok && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate 2>&1 | tail -5"
```

Expected: `== Running 20260416000001 ... == Migrated 20260416000001 in 0.0s`.

- [ ] **Step 5: Restart druzhok service**

```bash
ssh igor@158.160.78.230 "sudo systemctl restart druzhok"
```

Wait ~15 seconds for druzhok to come up.

- [ ] **Step 6: Verify druzhok is active**

```bash
ssh igor@158.160.78.230 "systemctl is-active druzhok"
```

Expected: `active`.

- [ ] **Step 7: Start the bot containers**

Open the dashboard in a browser (https://<remote>:4000 or however it's reached). For each bot that isn't running, click the "Start" button. `BotManager.start` runs `sync_config` which emits the new `group_shared_memory: false` key for each bot.

(Alternative: the user prefers manual start — defer to their workflow.)

- [ ] **Step 8: Verify yaml state after restart**

```bash
ssh igor@158.160.78.230 "sudo grep -c group_shared_memory /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml /home/igor/druzhok-data/v4-instances/hermes3/config.yaml"
```

Expected: each file has exactly 1 matching line.

```bash
ssh igor@158.160.78.230 "sudo grep group_shared_memory /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml /home/igor/druzhok-data/v4-instances/hermes3/config.yaml"
```

Expected: both say `group_shared_memory: false` (the default; feature starts off for every bot).

- [ ] **Step 9: UI smoke test**

In the dashboard, open Vasya's Settings tab. Verify both checkboxes render side-by-side:
- "Shared group memory — one conversation per group (instead of per user)" — checked (DB = false → UI inverted).
- "Record all group messages — bot reads everything, answers only when addressed" — unchecked (DB = false, not inverted).

- [ ] **Step 10: Behaviour smoke test (toggle on, then verify)**

In the dashboard, enable "Record all group messages" for Vasya. Wait for the restart to complete (~20s).

In Telegram group "Себаса Поскорей":
1. User A (Igor) sends a short message WITHOUT @Вася.
2. User B (Victor) sends another short message WITHOUT @Вася.
3. User A @Вася asks: "что я сейчас написал?" (what did I just write?).
4. Expected: Vasya responds accurately with the content of Igor's earlier message.

If step 4 fails: check the yaml has `group_shared_memory: true`, check the container logs for any passive-record errors with `ssh igor@158.160.78.230 "docker logs druzhok-bot-igorhermes 2>&1 | grep -i 'passive\\|record'"`.

- [ ] **Step 11: Leave the toggle in user's preferred state**

Ask the user whether they want to leave the feature on for Vasya. If yes, done. If no, toggle it off in the dashboard.

---

## Self-Review

**Spec coverage:**

- Spec section "Thread collapse" → Task 6.
- Spec section "Silent observer" → Task 7.
- Spec section "Druzhok-side changes" → Tasks 1, 2, 3, 4, 5.
- Spec section "update-hermes skill updates" → Task 8.
- Spec section "Testing" → unit tests in Tasks 3, 4; manual smoke in Task 9 steps 9-10.
- Spec section "Operational notes" → Task 9's deploy order and toggle guidance.

No gaps.

**Placeholder scan:** No TBDs / "add error handling" / "fill in" / "similar to Task N" patterns. Every code step shows the code.

**Type consistency:** `group_shared_memory` is used as a `:boolean` throughout — DB column (default false), schema field, config.extra lookup. `_record_passive_group_message` is used at one call site and defined once. `effective_thread_id` is a local variable in `_build_message_event`; no consumer outside that function. The function signature for `self._session_store.get_or_create_session(event.source)` matches the spec and session.py:682.

Consistent end-to-end.
