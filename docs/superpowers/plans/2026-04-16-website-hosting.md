# Website Hosting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship per-bot static website hosting — enable a toggle, and any files the bot writes to `/opt/data/workspace/sites/<name>/` become publicly reachable at `https://<bot>.oldey.dev/<name>/`.

**Architecture:** Caddy runs on the VM as a new systemd service, terminates TLS for `*.oldey.dev` with a wildcard cert, reverse-proxies `dashboard.oldey.dev` → Phoenix on `127.0.0.1:4000`, and file-serves `<bot>.oldey.dev` from each bot's `workspace/sites/` directory. Druzhok gets a new per-bot boolean column `website_hosting_enabled`, emits `BOT_SITE_BASE_URL` env var when on, and teaches the agent the publishing convention via a section appended to `workspace/AGENTS.md` (idempotent `sync_agents_md/2` helper covers existing bots).

**Tech Stack:** Caddy v2 (DNS-01 TLS), Elixir/Phoenix LiveView/Ecto/SQLite (druzhok), static HTML (default page), ExUnit tests.

**Spec:** `docs/superpowers/specs/2026-04-16-website-hosting-design.md`

---

## File Structure

**Create:**
- `v4/druzhok/apps/druzhok/priv/repo/migrations/20260416000002_add_website_hosting_enabled_to_instances.exs` — new boolean column.
- `v4/druzhok/apps/druzhok/lib/druzhok/site_lister.ex` — module that enumerates a bot's sites.
- `v4/druzhok/apps/druzhok/test/druzhok/site_lister_test.exs` — unit tests for SiteLister.
- `v4/druzhok/config/Caddyfile` — Caddy configuration, version-controlled.
- `v4/druzhok/priv/default-page/index.html` — druzhok-branded fallback page (deployed to `/opt/druzhok-assets/default-page/` on the host).

**Modify:**
- `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex` — add `website_hosting_enabled` field + include in `cast/3`.
- `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` — emit `BOT_SITE_BASE_URL` env var in `env_vars/1`, add `sync_agents_md/2` helper wired into `sync_config/2`.
- `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs` — add tests for the new env var and agents-md sync.
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — new "Website Hosting" section with toggle + read-only site list.
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex` — tighten session cookie settings before Caddy deploys.
- `v4/druzhok/workspace-template/AGENTS.md` — append "Публикация сайтов" section.

**Remote (VM) changes (deploy-time, Task 10):**
- Install Caddy via apt.
- Place `Caddyfile` at `/etc/caddy/Caddyfile`, enable systemd unit.
- Set up `CLOUDFLARE_API_TOKEN` (or equivalent DNS-provider) env var for Caddy.
- Add DNS wildcard `*.oldey.dev A <VM-ip>`.
- Deploy default-page assets to `/opt/druzhok-assets/default-page/`.
- Ensure dashboard subdomain DNS points to VM.

**No changes to:**
- Hermes source (no patches).
- The bot's file-write tool (agent writes via existing workspace write path).
- Any non-Telegram part of druzhok.

---

## Task 1: Migration

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260416000002_add_website_hosting_enabled_to_instances.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Druzhok.Repo.Migrations.AddWebsiteHostingEnabledToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :website_hosting_enabled, :boolean, default: false, null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration on dev DB**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
DATABASE_PATH=data/druzhok.db mix ecto.migrate
```

Expected: `[info] == Running 20260416000002 ...` + `[info] == Migrated in Nms`. No errors.

- [ ] **Step 3: Verify column**

```bash
sqlite3 /Users/igorkuznetsov/Documents/druzhok/v4/druzhok/data/druzhok.db "PRAGMA table_info(instances);" | grep website_hosting_enabled
```

Expected: a line with `website_hosting_enabled|INTEGER|1|0|0` (nullable 0 = NOT NULL, default 0).

- [ ] **Step 4: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/priv/repo/migrations/20260416000002_add_website_hosting_enabled_to_instances.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "migration: add website_hosting_enabled to instances (default false)"
```

---

## Task 2: Schema field + cast

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Add field**

In `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`, directly after:

```elixir
    field :group_shared_memory, :boolean, default: false
```

add:

```elixir
    field :website_hosting_enabled, :boolean, default: false
```

- [ ] **Step 2: Add to cast list**

In the `cast/3` call inside `changeset/2`, append `:website_hosting_enabled` at the end of the field list. The final list should end:

```
..., :dreaming, :group_sessions_per_user, :group_shared_memory, :website_hosting_enabled])
```

- [ ] **Step 3: Compile**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix compile --warnings-as-errors
```

Expected: compiles cleanly (ignore pre-existing Bcrypt warnings in `druzhok` app).

- [ ] **Step 4: Smoke test via mix run**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`, create `/tmp/smoke_hosting.exs`:

```elixir
cs = Druzhok.Instance.changeset(%Druzhok.Instance{}, %{
  name: "t", model: "m", workspace: "w", website_hosting_enabled: true
})
IO.inspect(cs.valid?, label: "valid?")
IO.inspect(Ecto.Changeset.get_change(cs, :website_hosting_enabled), label: "value")
```

Run: `DATABASE_PATH=data/druzhok.db mix run /tmp/smoke_hosting.exs`

Expected:
```
valid?: true
value: true
```

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/instance.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "schema: add website_hosting_enabled field + cast"
```

---

## Task 3: `env_vars/1` emits `BOT_SITE_BASE_URL`

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex` (`env_vars/1` body)
- Test: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`

- [ ] **Step 1: Write failing tests**

In `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`, append a new `describe` block before the final `end`:

```elixir
  describe "env_vars/1 — BOT_SITE_BASE_URL" do
    test "emits URL when hosting is enabled" do
      inst = Map.merge(@instance, %{website_hosting_enabled: true, name: "alice"})
      assert Hermes.env_vars(inst)["BOT_SITE_BASE_URL"] == "https://alice.oldey.dev"
    end

    test "emits empty string when hosting is disabled" do
      inst = Map.put(@instance, :website_hosting_enabled, false)
      assert Hermes.env_vars(inst)["BOT_SITE_BASE_URL"] == ""
    end

    test "defaults to empty string when key missing on instance map" do
      inst = Map.delete(@instance, :website_hosting_enabled)
      assert Hermes.env_vars(inst)["BOT_SITE_BASE_URL"] == ""
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: 3 new failures (key not present in env map).

- [ ] **Step 3: Add the env var**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, inside `env_vars/1`, right after the existing line:

```elixir
      "TELEGRAM_GROUP_SHARED_MEMORY" => to_string(Map.get(instance, :group_shared_memory, false)),
```

add:

```elixir
      # Druzhok website hosting: when enabled, the bot knows its public
      # base URL; otherwise this is empty and the agent refuses to
      # publish (see workspace/AGENTS.md "Публикация сайтов").
      "BOT_SITE_BASE_URL" => build_bot_site_base_url(instance),
```

Then, in the same file, add a helper near the end of the file before `end` of the module (alongside other private helpers like `build_mention_patterns`):

```elixir
  defp build_bot_site_base_url(instance) do
    if Map.get(instance, :website_hosting_enabled, false) do
      "https://#{instance.name}.oldey.dev"
    else
      ""
    end
  end
```

- [ ] **Step 4: Run tests**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass (existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "hermes: emit BOT_SITE_BASE_URL env var when website_hosting_enabled"
```

---

## Task 4: `sync_agents_md/2` — append section idempotently

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`
- Test: `v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs`

Existing bots' `workspace/AGENTS.md` files are created when the bot was provisioned; they don't have the "Публикация сайтов" section. This helper runs on every bot start and ensures it's there. For new bots, the template already ships the section (Task 6), so the helper is a no-op.

Because the section never needs variations (no per-instance substitution), idempotency check is a simple substring match.

- [ ] **Step 1: Define the section constant**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, near the top-level module attributes (alongside `@default_model`), add:

```elixir
  @agents_md_sites_section """
  ## Публикация сайтов

  Если пользователь просит сделать лендинг, сайт, демо-страницу и т.п.:

  1. Проверь переменную окружения `BOT_SITE_BASE_URL`. Если пусто — хостинг не включён; сообщи пользователю и не пиши файлы.
  2. Выбери короткое имя сайта (`^[a-z0-9][a-z0-9-]*$`, до 50 символов).
  3. Запиши все файлы в `/opt/data/workspace/sites/<имя>/`. Входная точка — `index.html`. Всего до ~50 MB на сайт, до ~100 файлов.
  4. Ответь пользователю одной кликабельной ссылкой: `$BOT_SITE_BASE_URL/<имя>/`.
  5. Удалить сайт: `rm -rf /opt/data/workspace/sites/<имя>/`.

  Файлы в `sites/<имя>/` публичны. Не клади туда секреты, токены, файлы, начинающиеся с точки.
  """
```

- [ ] **Step 2: Write failing tests**

Append another `describe` block in `hermes_test.exs` before the final `end`:

```elixir
  describe "sync_agents_md/2" do
    @tag :tmp_dir
    test "appends the sites section when absent", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nExisting content.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      content = File.read!(Path.join(workspace, "AGENTS.md"))
      assert content =~ "## Публикация сайтов"
      assert content =~ "BOT_SITE_BASE_URL"
    end

    @tag :tmp_dir
    test "is idempotent when section already present", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS.md\n\nExisting content.\n")

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      first = File.read!(Path.join(workspace, "AGENTS.md"))

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)
      second = File.read!(Path.join(workspace, "AGENTS.md"))

      assert first == second
    end

    @tag :tmp_dir
    test "is a no-op when AGENTS.md does not exist", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      assert :ok = Hermes.sync_agents_md(@instance, tmp_dir)

      refute File.exists?(Path.join(workspace, "AGENTS.md"))
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: 3 new failures (function does not exist).

- [ ] **Step 4: Add the public `sync_agents_md/2`**

In `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, after the existing `sync_group_sessions_per_user/2` helper, add:

```elixir
  def sync_agents_md(_instance, data_root) do
    agents_path = Path.join([data_root, "workspace", "AGENTS.md"])

    case File.read(agents_path) do
      {:ok, content} ->
        if String.contains?(content, "## Публикация сайтов") do
          :ok
        else
          updated = String.trim_trailing(content) <> "\n\n" <> @agents_md_sites_section
          File.write!(agents_path, updated)
          :ok
        end

      {:error, _} ->
        :ok
    end
  end
```

- [ ] **Step 5: Wire into `sync_config/2`**

In the `sync_config/2` function, the current pipeline is:

```elixir
        updated =
          content
          |> sync_model_default(model)
          |> sync_auxiliary_vision(vision_model, tenant_key)
          |> sync_group_sessions_per_user(instance)
```

`sync_agents_md/2` operates on a different file (AGENTS.md, not config.yaml), so it doesn't belong in the same pipeline. Instead, call it separately at the start of `sync_config/2`, before the `case File.read(config_path)`:

Replace the body of `sync_config/2` so it becomes:

```elixir
  def sync_config(instance, data_root) do
    sync_agents_md(instance, data_root)

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

        if updated != content, do: File.write!(config_path, updated)
        :ok

      {:error, _} ->
        :ok
    end
  end
```

- [ ] **Step 6: Run tests**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex v4/druzhok/apps/druzhok/test/druzhok/runtime/hermes_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "hermes: add sync_agents_md helper, wire into sync_config"
```

---

## Task 5: SiteLister module

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/site_lister.ex`
- Create: `v4/druzhok/apps/druzhok/test/druzhok/site_lister_test.exs`

Module scans `workspace/sites/*/` for a given instance and returns a list of `%{name, url, size, mtime}`. Pure function, no external deps — easy to test.

- [ ] **Step 1: Write failing tests**

Create `v4/druzhok/apps/druzhok/test/druzhok/site_lister_test.exs`:

```elixir
defmodule Druzhok.SiteListerTest do
  use ExUnit.Case, async: true

  alias Druzhok.SiteLister

  @instance %{
    name: "vasya",
    workspace: nil  # filled per test with tmp_dir path
  }

  describe "list/1" do
    @tag :tmp_dir
    test "returns empty list when sites directory is missing", %{tmp_dir: tmp_dir} do
      workspace = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(workspace)

      inst = %{@instance | workspace: workspace}
      assert SiteLister.list(inst) == []
    end

    @tag :tmp_dir
    test "returns a list entry per site subdirectory", %{tmp_dir: tmp_dir} do
      sites = Path.join([tmp_dir, "workspace", "sites"])
      File.mkdir_p!(Path.join(sites, "alpha"))
      File.mkdir_p!(Path.join(sites, "beta"))
      File.write!(Path.join([sites, "alpha", "index.html"]), "<h1>A</h1>")
      File.write!(Path.join([sites, "beta", "index.html"]), "<h1>B</h1>")

      inst = %{@instance | workspace: Path.join(tmp_dir, "workspace")}
      result = SiteLister.list(inst) |> Enum.sort_by(& &1.name)

      assert length(result) == 2
      assert [a, b] = result
      assert a.name == "alpha"
      assert b.name == "beta"
      assert a.url == "https://vasya.oldey.dev/alpha/"
      assert b.url == "https://vasya.oldey.dev/beta/"
      assert a.size > 0
      assert b.size > 0
      assert %DateTime{} = a.mtime
    end

    @tag :tmp_dir
    test "ignores files at the top of sites/ (only directories are sites)", %{tmp_dir: tmp_dir} do
      sites = Path.join([tmp_dir, "workspace", "sites"])
      File.mkdir_p!(Path.join(sites, "real-site"))
      File.write!(Path.join([sites, "real-site", "index.html"]), "ok")
      File.write!(Path.join(sites, "stray-file.txt"), "not a site")

      inst = %{@instance | workspace: Path.join(tmp_dir, "workspace")}
      result = SiteLister.list(inst)

      assert length(result) == 1
      assert hd(result).name == "real-site"
    end

    @tag :tmp_dir
    test "size is the recursive byte total of the site directory", %{tmp_dir: tmp_dir} do
      sites = Path.join([tmp_dir, "workspace", "sites"])
      File.mkdir_p!(Path.join(sites, "sized"))
      File.write!(Path.join([sites, "sized", "a.txt"]), String.duplicate("a", 100))
      File.write!(Path.join([sites, "sized", "b.txt"]), String.duplicate("b", 200))

      inst = %{@instance | workspace: Path.join(tmp_dir, "workspace")}
      [site] = SiteLister.list(inst)

      assert site.size == 300
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix test apps/druzhok/test/druzhok/site_lister_test.exs
```

Expected: 4 failures (module does not exist).

- [ ] **Step 3: Implement the module**

Create `v4/druzhok/apps/druzhok/lib/druzhok/site_lister.ex`:

```elixir
defmodule Druzhok.SiteLister do
  @moduledoc """
  Enumerate the static sites a bot has published under its workspace.

  Sites live at `<workspace>/sites/<site-name>/` — each subdirectory is
  one site. Returns a list of `%{name, url, size, mtime}` maps suitable
  for rendering in the dashboard.
  """

  @doc """
  Returns a list of sites for the given instance. Empty list when the
  `sites/` directory does not exist or the workspace is not set.
  """
  def list(%{name: _, workspace: nil}), do: []
  def list(%{name: bot_name, workspace: workspace}) do
    sites_dir = Path.join(workspace, "sites")

    case File.ls(sites_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(sites_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&to_site_entry(&1, bot_name))

      {:error, _} ->
        []
    end
  end

  defp to_site_entry(site_path, bot_name) do
    name = Path.basename(site_path)

    %{
      name: name,
      url: "https://#{bot_name}.oldey.dev/#{name}/",
      size: directory_size(site_path),
      mtime: directory_mtime(site_path)
    }
  end

  defp directory_size(path) do
    path
    |> walk_files()
    |> Enum.reduce(0, fn file, acc ->
      case File.stat(file) do
        {:ok, %File.Stat{size: s}} -> acc + s
        _ -> acc
      end
    end)
  end

  defp directory_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: posix}} -> DateTime.from_unix!(posix)
      _ -> DateTime.utc_now()
    end
  end

  defp walk_files(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.flat_map(fn entry -> walk_files(Path.join(path, entry)) end)

      true ->
        []
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test apps/druzhok/test/druzhok/site_lister_test.exs
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/site_lister.ex v4/druzhok/apps/druzhok/test/druzhok/site_lister_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "site_lister: enumerate bot's published sites"
```

---

## Task 6: Template `AGENTS.md` section

**Files:**
- Modify: `v4/druzhok/workspace-template/AGENTS.md`

- [ ] **Step 1: Append the section**

Open `v4/druzhok/workspace-template/AGENTS.md` and append (preserve the existing final `_Этот файл — стартовая точка._` marker at the very end; insert BEFORE it):

Find this block at the end of the file:

```markdown
---

_Этот файл — стартовая точка. Добавляй свои правила._
```

Replace it with:

```markdown
## Публикация сайтов

Если пользователь просит сделать лендинг, сайт, демо-страницу и т.п.:

1. Проверь переменную окружения `BOT_SITE_BASE_URL`. Если пусто — хостинг не включён; сообщи пользователю и не пиши файлы.
2. Выбери короткое имя сайта (`^[a-z0-9][a-z0-9-]*$`, до 50 символов).
3. Запиши все файлы в `/opt/data/workspace/sites/<имя>/`. Входная точка — `index.html`. Всего до ~50 MB на сайт, до ~100 файлов.
4. Ответь пользователю одной кликабельной ссылкой: `$BOT_SITE_BASE_URL/<имя>/`.
5. Удалить сайт: `rm -rf /opt/data/workspace/sites/<имя>/`.

Файлы в `sites/<имя>/` публичны. Не клади туда секреты, токены, файлы, начинающиеся с точки.

---

_Этот файл — стартовая точка. Добавляй свои правила._
```

- [ ] **Step 2: Verify**

```bash
grep -c "## Публикация сайтов" /Users/igorkuznetsov/Documents/druzhok/v4/druzhok/workspace-template/AGENTS.md
```

Expected: `1`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/workspace-template/AGENTS.md
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "template: add Публикация сайтов section to AGENTS.md"
```

---

## Task 7: Dashboard — Website Hosting section

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex`

Adds a new section in the Settings tab with a toggle and a read-only site list that renders only when the toggle is on.

- [ ] **Step 1: Add `SiteLister` alias + preload sites on mount**

Near the top of `settings_tab.ex`, find the `alias` line:

```elixir
  alias Druzhok.{Instance, Repo, Runtime, Pairing, Telegram, I18n, BotManager, ModelCatalog}
```

Change it to:

```elixir
  alias Druzhok.{Instance, Repo, Runtime, Pairing, Telegram, I18n, BotManager, ModelCatalog, SiteLister}
```

Find the `update/2` function (the LiveComponent callback). Inside it, after the line assigning `:instance`, add a derived assign for sites:

```elixir
    sites =
      case assigns[:instance] do
        %{website_hosting_enabled: true} = inst -> SiteLister.list(inst)
        _ -> []
      end

    {:ok, socket |> assign(assigns) |> assign(:sites, sites)}
```

Exact placement: find the existing `def update(assigns, socket) do` body. It likely currently ends with `{:ok, assign(socket, assigns)}` — replace that with the two-line construct above. If your `update/2` already builds assigns differently, splice the `sites` calculation in at the end before the `{:ok, ...}` return.

- [ ] **Step 2: Add the template section**

In the HEEx template portion of the file, find the section containing the existing "Group Chats" heading (`<h3 class="text-sm font-medium text-gray-700 mb-3">Group Chats</h3>`). Immediately after the closing `</div>` of that Group Chats section (and its trailing `<hr />`), insert a new section:

```heex
      <%!-- Website Hosting --%>
      <div>
        <h3 class="text-sm font-medium text-gray-700 mb-3">Website Hosting</h3>
        <label class="flex items-center gap-3 cursor-pointer select-none">
          <input type="checkbox" phx-click="toggle_website_hosting" phx-target={@myself}
                 phx-throttle="1000"
                 checked={@instance[:website_hosting_enabled]}
                 class="w-4 h-4 border border-line2 bg-panel accent-accent focus:ring-0 focus:ring-offset-0" />
          <span class="text-sm text-fg">
            Enable website hosting — publish static sites at <code>{@instance.name}.oldey.dev</code>
          </span>
        </label>

        <%= if @instance[:website_hosting_enabled] do %>
          <div class="mt-3">
            <%= if Enum.empty?(@sites) do %>
              <p class="text-xs text-gray-400">
                No sites published yet. Ask the bot to create one.
              </p>
            <% else %>
              <ul class="space-y-2">
                <%= for site <- @sites do %>
                  <li class="flex items-center justify-between text-sm border border-gray-200 rounded-lg px-3 py-2">
                    <div>
                      <a href={site.url} target="_blank" class="font-mono text-accent">
                        {site.url}
                      </a>
                      <div class="text-xs text-gray-500">
                        {format_bytes(site.size)} · updated {Calendar.strftime(site.mtime, "%Y-%m-%d %H:%M")}
                      </div>
                    </div>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </div>
        <% else %>
          <p class="text-xs text-gray-400 mt-1">
            Enable to let the bot publish static pages.
          </p>
        <% end %>
      </div>

      <hr class="border-gray-200" />
```

- [ ] **Step 3: Add `format_bytes/1` private helper**

Near the bottom of the module (before the final `end`), add:

```elixir
  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"
```

- [ ] **Step 4: Add the toggle event handler**

After the existing `toggle_group_shared_memory` handler, add:

```elixir
  def handle_event("toggle_website_hosting", _params, socket) do
    name = socket.assigns.instance.name
    current = socket.assigns.instance[:website_hosting_enabled]
    update_instance(name, %{website_hosting_enabled: !current})
    restart_bot(name)
    notify_parent(socket)
    {:noreply, socket}
  end
```

- [ ] **Step 5: Compile**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix compile --warnings-as-errors
```

Expected: clean (ignore pre-existing Bcrypt warnings).

- [ ] **Step 6: Run hermes tests (regression)**

```bash
mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs apps/druzhok/test/druzhok/site_lister_test.exs
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "dashboard: add Website Hosting toggle + read-only site list"
```

---

## Task 8: Harden dashboard session cookie

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex`

Current config at `endpoint.ex:7-12`:

```elixir
  @session_options [
    store: :cookie,
    key: "_druzhok_web_key",
    signing_salt: "9Ma3K3Mm",
    same_site: "Lax"
  ]
```

The cookie is already host-only (no explicit domain, defaults to the exact host — safe). `same_site: "Lax"` is acceptable but `Strict` is safer. `Secure` and `http_only` need to be explicit for prod.

- [ ] **Step 1: Tighten session options**

Replace the `@session_options` block above with:

```elixir
  # Session cookie is host-only (no domain set) so a hostile subdomain
  # (e.g. a malicious bot-hosted site at vasya.oldey.dev) cannot read
  # or overwrite it. SameSite=Strict prevents the cookie from being
  # sent on cross-site navigations — user must be actively on the
  # dashboard host. Secure + HttpOnly are standard hardening.
  @session_options [
    store: :cookie,
    key: "_druzhok_web_key",
    signing_salt: "9Ma3K3Mm",
    same_site: "Strict",
    secure: true,
    http_only: true
  ]
```

- [ ] **Step 2: Verify dev still works**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix compile --warnings-as-errors
```

Note: with `secure: true`, dev-mode HTTP will NOT receive the cookie. In dev, the team tolerates "you must use HTTPS locally" — or temporarily drops `secure: true` during dev. For now, leave it as `true` since this is a production-focused deploy; the dev experience is acceptable given the dashboard is primarily accessed on the deployed VM.

Alternative if dev becomes painful: make `secure` depend on `config_env()` via `runtime.exs`:

```elixir
secure: config_env() == :prod
```

That change is out of scope for this task; note it in the spec's open items.

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "security: tighten session cookie (Strict, Secure, HttpOnly)"
```

---

## Task 9: Caddyfile + default-page assets

**Files:**
- Create: `v4/druzhok/config/Caddyfile`
- Create: `v4/druzhok/priv/default-page/index.html`

- [ ] **Step 1: Write the Caddyfile**

Create `v4/druzhok/config/Caddyfile`:

```caddy
# Druzhok Caddy config — deployed to /etc/caddy/Caddyfile on the VM.
#
# Serves:
#   dashboard.oldey.dev → reverse proxy to Phoenix on 127.0.0.1:4000
#   <bot>.oldey.dev     → static file server from the bot's workspace
#   *.oldey.dev (any other host) → druzhok-branded default page
#
# TLS: wildcard cert obtained via DNS-01 against Cloudflare.
#
# Note to operator: CLOUDFLARE_API_TOKEN must be present in Caddy's
# environment (systemd unit or /etc/default/caddy). If DNS provider
# changes, adjust the tls block.

{
    email igor.n.kuz@gmail.com
}

*.oldey.dev {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }

    @dashboard host dashboard.oldey.dev
    handle @dashboard {
        reverse_proxy 127.0.0.1:4000
    }

    @botsite host_regexp bot ^([a-z0-9][a-z0-9-]+)\.oldey\.dev$
    handle @botsite {
        root * /home/igor/druzhok-data/v4-instances/{re.bot.1}/workspace/sites
        file_server {
            hide .* _*
        }
        handle_errors {
            root * /opt/druzhok-assets/default-page
            file_server
        }
    }

    # Fallback: no subdomain pattern matched — show default page.
    handle {
        root * /opt/druzhok-assets/default-page
        file_server
    }
}
```

- [ ] **Step 2: Write the default page HTML**

Create `v4/druzhok/priv/default-page/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>druzhok</title>
    <style>
        body {
            margin: 0;
            background: #0a0a0a;
            color: #e5e5e5;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            text-align: center;
        }
        .box {
            padding: 2rem;
            border: 1px solid #2a2a2a;
            border-radius: 8px;
            max-width: 32rem;
        }
        h1 { font-size: 1.5rem; margin-top: 0; color: #fff; }
        p { color: #888; line-height: 1.5; }
        a { color: #6aa6ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="box">
        <h1>Nothing here yet</h1>
        <p>
            This subdomain is part of the
            <a href="https://dashboard.oldey.dev">druzhok</a>
            bot hosting platform. The bot who owns this subdomain hasn't
            published a site here yet, or the path you requested doesn't exist.
        </p>
    </div>
</body>
</html>
```

- [ ] **Step 3: Lint-check the Caddyfile locally if Caddy is available**

If Caddy is installed locally:

```bash
caddy validate --config /Users/igorkuznetsov/Documents/druzhok/v4/druzhok/config/Caddyfile
```

Expected: no errors. If Caddy isn't installed locally, skip — the VM install in Task 10 will validate on start.

- [ ] **Step 4: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/config/Caddyfile v4/druzhok/priv/default-page/index.html
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "caddy: config + default-page assets for website hosting"
```

---

## Task 10: Deploy to production

Operational task. All code must be committed + pushed to `origin/main` before this task begins. Requires the user's Cloudflare API token (or chosen DNS provider's equivalent) and DNS-record edit access.

- [ ] **Step 1: Push local commits + pull on remote**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok push origin main
ssh igor@158.160.78.230 "cd ~/druzhok && git pull --ff-only 2>&1 | tail -5"
```

Expected: the new commits land on the remote.

- [ ] **Step 2: Run the migration on prod DB**

```bash
ssh igor@158.160.78.230 "source ~/.bashrc; . ~/.asdf/asdf.sh; cd ~/druzhok/v4/druzhok && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate 2>&1 | tail -3"
```

Expected: `== Migrated 20260416000002 in 0.0s`.

- [ ] **Step 3: Install Caddy on the VM**

```bash
ssh igor@158.160.78.230 "sudo apt-get update && sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list && sudo apt-get update && sudo apt-get install -y caddy"
```

Expected: Caddy installed, systemd service present.

- [ ] **Step 4: Install Caddy's Cloudflare DNS plugin**

Caddy's core binary doesn't include third-party DNS modules. Rebuild Caddy with `xcaddy`, or use Caddy's built-in module download:

```bash
ssh igor@158.160.78.230 "sudo caddy add-package github.com/caddy-dns/cloudflare"
```

Expected: module added, Caddy binary rebuilt. If the `caddy add-package` command isn't available in the installed version, fall back to xcaddy:

```bash
ssh igor@158.160.78.230 "
  sudo apt-get install -y golang-go &&
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest &&
  ~/go/bin/xcaddy build --with github.com/caddy-dns/cloudflare --output /tmp/caddy-with-cloudflare &&
  sudo mv /tmp/caddy-with-cloudflare /usr/bin/caddy &&
  sudo chmod +x /usr/bin/caddy
"
```

Verify:

```bash
ssh igor@158.160.78.230 "caddy list-modules | grep cloudflare"
```

Expected: `dns.providers.cloudflare` listed.

- [ ] **Step 5: Configure DNS wildcard**

In the Cloudflare dashboard (or wherever `oldey.dev` DNS is managed), add:

```
*.oldey.dev   A   158.160.78.230   (or whatever the VM IP is)
```

Also confirm `dashboard.oldey.dev` A record exists and points to the VM (probably does already).

Verify:

```bash
dig +short A foo.oldey.dev
dig +short A dashboard.oldey.dev
```

Expected: both return the VM IP.

- [ ] **Step 6: Obtain a Cloudflare API token**

In Cloudflare → My Profile → API Tokens → Create Token. Permissions required: `Zone:Read` and `Zone.DNS:Edit` scoped to the `oldey.dev` zone. Copy the token — it's only shown once.

- [ ] **Step 7: Install the token + Caddyfile on the VM**

```bash
ssh igor@158.160.78.230 "sudo mkdir -p /etc/caddy && sudo cp ~/druzhok/v4/druzhok/config/Caddyfile /etc/caddy/Caddyfile"

# Put the API token in systemd drop-in so it's in Caddy's environment:
ssh igor@158.160.78.230 "sudo mkdir -p /etc/systemd/system/caddy.service.d && cat | sudo tee /etc/systemd/system/caddy.service.d/override.conf" <<EOF
[Service]
Environment=CLOUDFLARE_API_TOKEN=<PASTE-TOKEN-HERE>
EOF

ssh igor@158.160.78.230 "sudo systemctl daemon-reload"
```

Replace `<PASTE-TOKEN-HERE>` with the actual token before running.

- [ ] **Step 8: Deploy default-page assets**

```bash
ssh igor@158.160.78.230 "sudo mkdir -p /opt/druzhok-assets/default-page && sudo cp ~/druzhok/v4/druzhok/priv/default-page/index.html /opt/druzhok-assets/default-page/index.html"
```

Verify:

```bash
ssh igor@158.160.78.230 "ls -la /opt/druzhok-assets/default-page/"
```

Expected: `index.html` present.

- [ ] **Step 9: Start Caddy + watch it provision the wildcard cert**

```bash
ssh igor@158.160.78.230 "sudo systemctl enable caddy && sudo systemctl start caddy && sleep 10 && sudo journalctl -u caddy --since '1 min ago' --no-pager | tail -40"
```

Expected: log shows `certificate obtained successfully` for `*.oldey.dev`. If it fails, logs will show the error (typically: bad API token, DNS-propagation delay, or wrong zone).

- [ ] **Step 10: Test the dashboard through Caddy**

From your local machine:

```bash
curl -sI https://dashboard.oldey.dev | head -5
```

Expected: `HTTP/2 200` (or 302 redirect to login).

- [ ] **Step 11: Test an unknown bot subdomain → default page**

```bash
curl -s https://nobot.oldey.dev | grep -o '<h1>[^<]*</h1>'
```

Expected: `<h1>Nothing here yet</h1>` from the default-page HTML.

- [ ] **Step 12: Restart druzhok service so it picks up new code (env var emitter)**

```bash
ssh igor@158.160.78.230 "sudo systemctl restart druzhok"
```

Wait ~10s, then:

```bash
ssh igor@158.160.78.230 "systemctl is-active druzhok"
```

Expected: `active`.

- [ ] **Step 13: Restart both bots so each picks up the new AGENTS.md section**

```bash
ssh igor@158.160.78.230 "source ~/.bashrc; . ~/.asdf/asdf.sh; cd ~/druzhok/v4/druzhok; DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db LLM_PROXY_HOST=127.0.0.1 mix run --no-start -e '
Application.ensure_all_started(:druzhok)
Druzhok.InstanceManager.list()
|> Enum.filter(& &1.active && &1.bot_runtime == \"hermes\")
|> Enum.each(fn inst ->
  IO.puts(\"Restarting #{inst.name}...\")
  Druzhok.BotManager.restart(inst.name)
  Process.sleep(3000)
end)
' 2>&1 | grep -E 'Restarting|Started|Done' | tail -5"
```

Verify the agents_md sync ran:

```bash
ssh igor@158.160.78.230 "sudo grep -c 'Публикация сайтов' /home/igor/druzhok-data/v4-instances/igorhermes/workspace/AGENTS.md /home/igor/druzhok-data/v4-instances/hermes3/workspace/AGENTS.md"
```

Expected: each file has the section exactly once.

- [ ] **Step 14: End-to-end smoke test**

In the dashboard (https://dashboard.oldey.dev), open Vasya's (`igorhermes`) Settings tab. The new "Website Hosting" section should appear below "Group Chats" with an unchecked checkbox and "Enable to let the bot publish static pages" helper text.

Toggle it on. Wait ~20s for the bot restart.

In Telegram, ask Vasya: "Вася, сделай лендинг про ремонт BMW N63. Отправь ссылку." (or similar).

Expected:
- Vasya writes files to `/opt/data/workspace/sites/<name>/` (you'll see them appear on disk).
- She replies with a URL of the form `https://vasya.oldey.dev/<name>/`.
- Opening that URL in a browser renders her HTML.
- Refresh the dashboard Settings tab → the site appears in the Website Hosting list with size and timestamp.

Then test fallback cases:

```bash
curl -s https://vasya.oldey.dev/this-does-not-exist/ | grep '<h1>'
```

Expected: default-page `<h1>`.

- [ ] **Step 15: Verify cookie audit**

From a browser's devtools Network tab, visit `https://dashboard.oldey.dev`, find the Set-Cookie header for `_druzhok_web_key`. Confirm:

- `Domain` attribute is absent (host-only)
- `Secure` present
- `SameSite=Strict`
- `HttpOnly` present

If any of these are wrong, address before leaving the deploy unattended.

---

## Self-Review

**Spec coverage**:
- Architecture (Caddy, wildcard cert, docroot) → Task 9 (Caddyfile), Task 10 (deploy).
- Per-bot `website_hosting_enabled` column + env var → Tasks 1, 2, 3.
- `sync_agents_md/2` idempotent helper → Task 4.
- `SiteLister` module → Task 5.
- Template AGENTS.md section → Task 6.
- Dashboard toggle + read-only list → Task 7.
- Security: cookie hardening (Task 8), docroot scoping + regex + dotfile hiding (Task 9 Caddyfile).
- Default page → Task 9, Task 10 step 8.
- DNS + cert provisioning → Task 10 steps 5, 6, 7, 9.
- End-to-end smoke + cookie audit → Task 10 steps 14, 15.

No gaps.

**Placeholder scan**: No "TBD", no "similar to task N", all code blocks present. One instance where a CLOUDFLARE_API_TOKEN must be manually pasted in Task 10 step 7 — that's a user secret, not a placeholder.

**Type consistency**: `website_hosting_enabled` is `:boolean` throughout (migration, schema, cast, handler). `BOT_SITE_BASE_URL` is `String.t`, empty when disabled — checked in tests (Task 3). `SiteLister.list/1` returns `[%{name, url, size, mtime}]` — callers in Task 7 use exactly these keys. `sync_agents_md/2` takes `(instance, data_root)` — matches the existing `sync_*` helper signatures in Task 4.
