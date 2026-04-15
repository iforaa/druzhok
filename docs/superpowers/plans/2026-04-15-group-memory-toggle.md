# Group Memory Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose `group_sessions_per_user` as a per-instance boolean toggle in the druzhok dashboard so operators can flip group-chat behaviour from isolated per-user sessions to one shared "room brain" without editing config.yaml by hand.

**Architecture:** Add a boolean column to `instances`, cast it in the Ecto changeset, emit it at the top level of the generated `config.yaml` from both the one-time seed (`build_config_yaml/1`) and the on-every-start patch (`sync_config/2`), and surface a checkbox in the instance settings component that mirrors the existing `mention_only` pattern. No hermes source changes — we only write to a stable public config key (`gateway/config.py:252`).

**Tech Stack:** Elixir / Phoenix LiveView / Ecto / SQLite. Tests with ExUnit.

**Spec:** `docs/superpowers/specs/2026-04-15-group-memory-toggle-design.md`

---

## File Structure

**Create:**
- `v4/druzhok/apps/druzhok/priv/repo/migrations/20260415000001_add_group_sessions_per_user_to_instances.exs` — adds boolean column with default `true`.

**Modify:**
- `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex` — add field to schema (line ~36 area) and to the `cast/3` whitelist (line 45).
- `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` — emit the key in `build_config_yaml/1` (seed) and patch in `sync_config/2` via a new `sync_group_sessions_per_user/2` helper (~line 119).
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — add a second checkbox under the existing "Group Chats" section (after line 237), plus a `toggle_group_sessions_per_user` event handler matching the pattern of `toggle_mention_only` (after line 350).
- `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` — add tests for `build_config_yaml/1` emission and `sync_config/2` patching behaviour.

**Remote data changes (deploy step, not code):**
- `/home/igor/druzhok-data/v4-druzhok.db` — one-row update to set `group_sessions_per_user = false` for `igorhermes` before the first bot restart under the new code.
- `/home/igor/druzhok-data/v4-instances/igorhermes/config.yaml` — remove the manual `group_sessions_per_user: false` line appended on 2026-04-15.

---

## Task 1: Migration

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260415000001_add_group_sessions_per_user_to_instances.exs`

- [ ] **Step 1: Write the migration file**

```elixir
defmodule Druzhok.Repo.Migrations.AddGroupSessionsPerUserToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :group_sessions_per_user, :boolean, default: true, null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration against the dev DB**

From `v4/druzhok`:
```bash
DATABASE_PATH=data/druzhok.db mix ecto.migrate
```

Expected output: `[info] == Running 20260415000001 ...` followed by `[info] == Migrated in Nms`. No errors.

- [ ] **Step 3: Verify column exists on the dev DB**

```bash
sqlite3 v4/druzhok/data/druzhok.db "PRAGMA table_info(instances);" | grep group_sessions_per_user
```

Expected: one line showing the column with `BOOLEAN` type and default `1` (SQLite stores booleans as integers).

- [ ] **Step 4: Commit**

```bash
cd v4/druzhok
git add apps/druzhok/priv/repo/migrations/20260415000001_add_group_sessions_per_user_to_instances.exs
git commit -m "migration: add group_sessions_per_user to instances (default true)"
```

---

## Task 2: Schema field and changeset cast

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex:36` (add field) and `:45` (add to cast list)

- [ ] **Step 1: Add the field to the schema block**

In `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`, after the existing `field :dreaming, :boolean, default: false` on line 36, add:

```elixir
    field :group_sessions_per_user, :boolean, default: true
```

- [ ] **Step 2: Add the field to the cast whitelist**

In the same file on line 45 (inside `changeset/2`), append `:group_sessions_per_user` to the list passed to `cast/3`. The list is long — add it at the very end so the diff is small:

```elixir
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key, :daily_token_limit, :dream_hour, :language, :tenant_key, :bot_runtime, :on_demand_model, :mention_only, :reject_message, :welcome_message, :allowed_telegram_ids, :allowed_telegram_chats, :allow_all_telegram_users, :trigger_name, :image_model, :audio_model, :embedding_model, :heartbeat_active_start, :heartbeat_active_end, :heartbeat_target, :fallback_models, :dreaming, :group_sessions_per_user])
```

- [ ] **Step 3: Smoke-test the changeset in IEx**

From `v4/druzhok`:
```bash
DATABASE_PATH=data/druzhok.db iex -S mix
```

Inside IEx:
```elixir
cs = Druzhok.Instance.changeset(%Druzhok.Instance{}, %{name: "t", model: "m", workspace: "w", group_sessions_per_user: false})
cs.valid?
# => true
Ecto.Changeset.get_change(cs, :group_sessions_per_user)
# => false
```

Expected: `true`, then `false`. Exit IEx with `Ctrl-C, Ctrl-C`.

- [ ] **Step 4: Compile to catch typos**

```bash
cd v4/druzhok && mix compile --warnings-as-errors
```

Expected: compiles clean. If warnings about unused modules appear, ignore — they must pre-exist.

- [ ] **Step 5: Commit**

```bash
cd v4/druzhok
git add apps/druzhok/lib/druzhok/instance.ex
git commit -m "schema: add group_sessions_per_user field + cast"
```

---

## Task 3: Emit key from `build_config_yaml/1` (first-boot seed)

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex:257-301`
- Test: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`

- [ ] **Step 1: Write the failing test**

In `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`, append a new `describe` block before the final `end`:

```elixir
  describe "build_config_yaml/1" do
    test "emits group_sessions_per_user: true when set" do
      inst = Map.put(@instance, :group_sessions_per_user, true)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_sessions_per_user: true$/m
    end

    test "emits group_sessions_per_user: false when set" do
      inst = Map.put(@instance, :group_sessions_per_user, false)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_sessions_per_user: false$/m
    end

    test "defaults to true when key missing on the instance map" do
      inst = Map.delete(@instance, :group_sessions_per_user)
      yaml = Hermes.build_config_yaml(inst)
      assert yaml =~ ~r/^group_sessions_per_user: true$/m
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

From `v4/druzhok`:
```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs:build_config_yaml
```

Two failures expected:
1. `build_config_yaml/1` is defined as a private `defp`, so it's inaccessible from tests.
2. Even if accessible, the YAML doesn't contain the key yet.

We'll fix (1) first by flipping the function to public, then fix (2) by emitting the key.

- [ ] **Step 3: Make `build_config_yaml` public**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex:257`, change `defp build_config_yaml(instance) do` to `def build_config_yaml(instance) do`.

Rationale: it's already used by the behaviour (via `workspace_files/1`) and adding a test coverage for it is a reason to expose it.

- [ ] **Step 4: Emit the key inside the heredoc**

In the same file, in `build_config_yaml/1`, after reading the `tenant_key` and before the triple-quoted heredoc, add:

```elixir
    group_sessions_per_user = Map.get(instance, :group_sessions_per_user, true)
```

Then inside the heredoc (around line 300, after the `auxiliary:` block), append a new top-level line so the final heredoc ends with:

```elixir
    auxiliary:
      vision:
        provider: custom
        base_url: "#{url}"
        api_key: "#{tenant_key}"
        model: "#{vision_model}"

    group_sessions_per_user: #{group_sessions_per_user}
    """
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs:build_config_yaml
```

Expected: 3 tests pass.

- [ ] **Step 6: Run the full hermes test file to catch regressions**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass (existing ones plus the 3 new ones).

- [ ] **Step 7: Commit**

```bash
cd v4/druzhok
git add apps/druzhok/lib/druzhok/runtime/hermes.ex apps/druzhok/test/druzhok/runtime/hermes_test.exs
git commit -m "hermes: seed group_sessions_per_user into generated config.yaml"
```

---

## Task 4: Patch key from `sync_config/2` on every restart

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex:102-125` (sync_config) plus new helper near line 161.
- Test: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`

Why a sync step as well as a seed: bots created before this migration have config.yaml files without the key. `sync_config` runs on every container start and is the mechanism druzhok already uses to keep dashboard-owned fields authoritative. Pattern matches the existing `sync_model_default/2` and `sync_auxiliary_vision/3`.

- [ ] **Step 1: Write the failing tests**

Append another `describe` block to `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`:

```elixir
  describe "sync_config/2 — group_sessions_per_user" do
    @tag :tmp_dir
    test "appends the key when absent", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")

      inst = Map.put(@instance, :group_sessions_per_user, false)
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert yaml =~ ~r/^group_sessions_per_user: false$/m
    end

    @tag :tmp_dir
    test "overwrites an existing value rather than duplicating", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"

      group_sessions_per_user: true
      """)

      inst = Map.put(@instance, :group_sessions_per_user, false)
      assert :ok = Hermes.sync_config(inst, tmp_dir)

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      matches = Regex.scan(~r/^group_sessions_per_user:/m, yaml)
      assert length(matches) == 1
      assert yaml =~ ~r/^group_sessions_per_user: false$/m
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs -t tmp_dir
```

Expected: two failures — the key is never emitted because `sync_config/2` doesn't know about it yet.

- [ ] **Step 3: Add the helper function**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, after `sync_auxiliary_vision/3` ends (around line 161), add:

```elixir
  defp sync_group_sessions_per_user(content, instance) do
    value = Map.get(instance, :group_sessions_per_user, true)
    line = "group_sessions_per_user: #{value}"

    if Regex.match?(~r/^group_sessions_per_user:.*$/m, content) do
      Regex.replace(~r/^group_sessions_per_user:.*$/m, content, line)
    else
      String.trim_trailing(content) <> "\n\n" <> line <> "\n"
    end
  end
```

- [ ] **Step 4: Wire the helper into `sync_config/2`**

In the same file, update the pipeline inside `sync_config/2` (currently lines 114-117). Change:

```elixir
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
```

to:

```elixir
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
```

- [ ] **Step 5: Run the tests**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass (existing + 3 from Task 3 + 2 from this task).

- [ ] **Step 6: Commit**

```bash
cd v4/druzhok
git add apps/druzhok/lib/druzhok/runtime/hermes.ex apps/druzhok/test/druzhok/runtime/hermes_test.exs
git commit -m "hermes: patch group_sessions_per_user in sync_config on every start"
```

---

## Task 5: UI toggle in `settings_tab.ex`

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` around line 237 (template) and 350 (handler).

- [ ] **Step 1: Add the checkbox to the template**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex`, find the "Group Chats" section (starts line 229). The existing "Mention only" checkbox ends at line 237. Immediately after its closing `</label>` and before the `<form phx-submit="save_trigger_name" ...>`, insert:

```heex
        <label class="flex items-center gap-3 cursor-pointer select-none mt-3">
          <input type="checkbox" phx-click="toggle_group_sessions_per_user" phx-target={@myself}
                 phx-throttle="1000"
                 checked={!@instance[:group_sessions_per_user]}
                 class="w-4 h-4 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0" />
          <span class="text-sm text-fg">Shared group memory — one conversation per group (instead of per user)</span>
        </label>
```

Note on semantics: the dashboard checkbox reads "shared group memory" (the user-facing concept). The underlying DB value is `group_sessions_per_user` (hermes's concept, which is the opposite). We invert with `!` in `checked=` and in the handler. This keeps the DB column name in sync with the upstream yaml key while the UI reads naturally.

- [ ] **Step 2: Add the event handler**

In the same file, after the `toggle_mention_only` handler (ends line 350), insert:

```elixir
  def handle_event("toggle_group_sessions_per_user", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:group_sessions_per_user]
    # UI shows "shared" when DB value is false; toggling flips it.
    update_instance(name, %{group_sessions_per_user: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end
```

- [ ] **Step 3: Compile and run the full web test suite**

```bash
cd v4/druzhok && mix compile --warnings-as-errors && mix test
```

Expected: compiles clean, existing tests pass. There is no dedicated LiveView test for `settings_tab` and we're matching an already-tested pattern — no additional unit test required here.

- [ ] **Step 4: Manual smoke test on dev**

Start Phoenix locally:
```bash
cd v4/druzhok && DATABASE_PATH=data/druzhok.db mix phx.server
```

Open the dashboard, navigate to a bot's Settings tab, toggle "Shared group memory" on and off. Verify the checkbox state persists after a page reload (DB write worked) and that a `BotManager.restart` is attempted in the logs.

- [ ] **Step 5: Commit**

```bash
cd v4/druzhok
git add apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex
git commit -m "dashboard: add shared group memory toggle under Group Chats"
```

---

## Task 6: Deploy to production with Vasya handoff

This task is **operational, not code**. The code and migration must already be committed (tasks 1-5 done) and pushed to the production branch before starting.

- [ ] **Step 1: Pull the code on the remote**

```bash
ssh igor@158.160.78.230 "cd ~/druzhok && git pull"
```

Expected: fast-forward pulling the five commits from tasks 1-5.

- [ ] **Step 2: Run the migration on the production DB**

```bash
ssh igor@158.160.78.230 "source ~/.bashrc; . ~/.asdf/asdf.sh; cd ~/druzhok/v4/druzhok && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate"
```

Expected: runs `20260415000001` to completion.

- [ ] **Step 3: Backfill Vasya's DB row to `false` BEFORE any bot restart**

This must happen before druzhok service restart, otherwise the first restart would emit `true` (the column default) into Vasya's yaml — overriding her current manual `false` and briefly reverting her behaviour.

```bash
ssh igor@158.160.78.230 "sudo sqlite3 /home/igor/druzhok-data/v4-druzhok.db \"UPDATE instances SET group_sessions_per_user = 0 WHERE name = 'igorhermes';\""
```

Then verify:
```bash
ssh igor@158.160.78.230 "sudo sqlite3 /home/igor/druzhok-data/v4-druzhok.db \"SELECT name, group_sessions_per_user FROM instances;\""
```

Expected:
```
hermes2|1
hermes3|1
igorhermes|0
```

- [ ] **Step 4: Remove the manual yaml append from Vasya's config**

```bash
ssh igor@158.160.78.230 "sudo cp /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml.before-dashboard-feature"
ssh igor@158.160.78.230 "sudo sed -i '/^# Collapse per-user group sessions into one shared room brain$/,/^group_sessions_per_user: false$/d' /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml"
```

Verify the tail no longer has the manual append:
```bash
ssh igor@158.160.78.230 "sudo tail -5 /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml"
```

Expected: ends with `TELEGRAM_HOME_CHANNEL: '-1002273542926'` (or similar), no `group_sessions_per_user` line.

- [ ] **Step 5: Restart druzhok service**

```bash
ssh igor@158.160.78.230 "sudo systemctl restart druzhok"
```

Wait ~15 seconds, then check:
```bash
ssh igor@158.160.78.230 "docker ps --format '{{.Names}}\t{{.Status}}'"
```

Expected: both `druzhok-bot-hermes3` and `druzhok-bot-igorhermes` healthy.

- [ ] **Step 6: Verify yaml state after restart**

```bash
ssh igor@158.160.78.230 "sudo grep -c group_sessions_per_user /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml /home/igor/druzhok-data/v4-instances/hermes3/config.yaml"
```

Expected:
```
/home/igor/druzhok-data/v4-instances/igorhermes/config.yaml:1
/home/igor/druzhok-data/v4-instances/hermes3/config.yaml:1
```

Each file has **exactly one** line with the key (sync_config replaced existing, or appended if absent).

Then:
```bash
ssh igor@158.160.78.230 "sudo grep group_sessions_per_user /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml /home/igor/druzhok-data/v4-instances/hermes3/config.yaml"
```

Expected:
```
.../igorhermes/config.yaml:group_sessions_per_user: false
.../hermes3/config.yaml:group_sessions_per_user: true
```

- [ ] **Step 7: UI smoke test on production**

Open the production dashboard, go to Vasya's (`igorhermes`) Settings tab. Verify "Shared group memory" is **checked** (because DB = false → UI shows on). Go to Рун's (`hermes3`) Settings tab; verify the box is **unchecked** (DB = true, default). No toggling yet — just confirm the read path matches.

- [ ] **Step 8: Behaviour smoke test in Vasya's group**

In Telegram group "Себаса Поскорей":
1. From user A (Igor): send two or three short messages @mentioning Vasya, building up context.
2. From user B (Victor): @mention Vasya and ask about what user A just said. Verify Vasya answers with knowledge from user A's messages. (Before this change, she could not.)

- [ ] **Step 9: Done — clean up**

If everything is green, the backup yaml file created in step 4 can be deleted after a day or two to free disk:

```bash
ssh igor@158.160.78.230 "sudo rm /home/igor/druzhok-data/v4-instances/igorhermes/config.yaml.before-dashboard-feature"
```

---

## Self-Review

**Spec coverage:** Every section of the spec maps to at least one task. Migration → Task 1; schema → Task 2; config emission (both seed and sync) → Tasks 3, 4; UI → Task 5; deploy order with Vasya handoff → Task 6. Testing section → covered in Tasks 3, 4 (unit) and Task 6 (manual smoke). Rollback → covered at spec level (down-migration drops the column), not needed as a separate task unless we invoke it.

**Placeholder scan:** None.

**Type consistency:** `group_sessions_per_user` is `:boolean` throughout (migration, schema field, changeset cast, DB stored as `0/1` in SQLite, yaml emission via `to_string/1` giving `"true"/"false"`). Handler uses `!current` negation. UI `checked` uses `!@instance[:group_sessions_per_user]` to keep "Shared group memory" label aligned with hermes's opposite-sense flag. Consistent end-to-end.
