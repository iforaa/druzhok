# Systemd Host Backend — Druzhok Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Druzhok's Docker bot launcher with a `Druzhok.Host` behaviour (systemd in prod, plain process in dev), delete the dead Docker/sandbox/Honcho/multi-runtime code, turn `HealthMonitor` into a real probe, and require tenant auth on every proxy route — with `mix test` green at the end of every task.

**Architecture:** `BotManager` keeps owning the lifecycle (env/config generation via `Runtime.Hermes`, DB state, data-dir wipe) but delegates process control to `Druzhok.Host` — `Host.Systemd` shells out to a root helper `sudo druzhok-ctl`, `Host.Process` spawns `hermes gateway run` as an Erlang port for local dev/tests. Everything Docker-, sandbox-, OpenClaw-, or Honcho-specific is removed. This plan is pure Elixir; the server-side files (`druzhok-ctl`, unit, nftables, bootstrap) are in the companion plan `2026-08-23-systemd-host-ops.md`.

**Tech Stack:** Elixir 1.17 / OTP 27 umbrella (`v4/druzhok`), Phoenix 1.7 + LiveView 1.0, Ecto + SQLite (`ecto_sqlite3`), Finch, Bandit, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-23-systemd-host-kz-migration-design.md`

## Global Constraints

- All paths below are relative to `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok` unless they start with `docs/` or `~/`.
- Run tests with `mix test` from `v4/druzhok` (umbrella root). Test DB is `data/druzhok_test.db`; if a migration is added run `MIX_ENV=test mix ecto.migrate` first.
- Commit with the `/my-commit` skill (project rule). Commit messages in the steps are the intended content; the skill formats them.
- Never run `git add -A` from the repo root — `v4/hermes-agent`, `v4/openclaw` etc. are untracked upstream clones. Add files explicitly.
- Bot name regex everywhere: `^[a-z0-9][a-z0-9-]{0,30}$`.
- Only runtime left is `"hermes"`. `instance.bot_runtime` column stays; value is always `"hermes"`.
- `Host` callbacks (exact): `start(name, env, data_root)`, `stop(name)`, `destroy(name)`, `status(name)`, `stats(name)`, `exec(name, args)`, `logs(name, lines)` — see Task 3.
- Host implementation is chosen by `Application.get_env(:druzhok, :host)`; default `Druzhok.Host.Process`; prod (`config/runtime.exs`) sets `Druzhok.Host.Systemd` when `DRUZHOK_HOST=systemd`.
- Data root default: `DRUZHOK_DATA_ROOT` env, else `/data/tenants` when `config_env() == :prod`, else `<repo>/v4/data/tenants` (current behaviour).

---

## File Structure

**Created**
- `apps/druzhok/lib/druzhok/host.ex` — behaviour + `impl/0` dispatcher.
- `apps/druzhok/lib/druzhok/host/process.ex` — dev/test implementation (GenServer per bot under `Druzhok.Host.ProcessSup`).
- `apps/druzhok/lib/druzhok/host/systemd.ex` — prod implementation (`sudo druzhok-ctl`).
- `apps/druzhok/lib/druzhok/health_monitor/probe.ex` — pure probe functions (unit, telegram, llm, egress).
- `apps/druzhok/priv/repo/migrations/20260823000001_drop_honcho_system_tenant.exs`.
- `apps/druzhok/test/support/fake_hermes.sh`, `apps/druzhok/test/support/fake_druzhok_ctl.sh` — stubs.
- `apps/druzhok/test/druzhok/host/process_test.exs`, `apps/druzhok/test/druzhok/host/systemd_test.exs`, `apps/druzhok/test/druzhok/health_monitor/probe_test.exs`.
- `apps/druzhok_web/test/druzhok_web_web/router_auth_test.exs`.

**Modified**
- `apps/druzhok/lib/druzhok/application.ex` — children list.
- `apps/druzhok/lib/druzhok/bot_manager.ex` — delegate to `Host`.
- `apps/druzhok/lib/druzhok/runtime.ex` — callbacks, registry, `proxy_host`.
- `apps/druzhok/lib/druzhok/runtime/hermes.ex` — `data_root/1`, drop honcho + UID.
- `apps/druzhok/lib/druzhok/instance.ex`, `instance_manager.ex` — drop sandbox/honcho.
- `apps/druzhok/lib/druzhok/health_monitor.ex` — probe loop.
- `apps/druzhok/lib/druzhok/i18n.ex` — drop sandbox strings.
- `apps/druzhok_web/lib/druzhok_web_web/router.ex`, `endpoint.ex`, `live/dashboard_live.ex`, `live/components/settings_tab.ex`, `controllers/llm_proxy_controller.ex`.
- `config/config.exs`, `config/runtime.exs`, `config/test.exs`.
- `CLAUDE.md`, `v4/druzhok/README.md`, `~/.claude/skills/update-hermes/SKILL.md`.

**Deleted** — listed in Task 1 and Task 2.

---

### Task 1: Delete dead subsystems and fix stale tests

Removes everything that the Docker/sandbox/OpenClaw era left behind and that nothing calls. After this task `mix test` is green for the first time in months.

**Files:**
- Delete: `apps/druzhok/lib/druzhok/sandbox.ex`, `apps/druzhok/lib/druzhok/sandbox/` (whole dir), `apps/druzhok/lib/druzhok/instance/sup.ex`, `apps/druzhok/lib/druzhok/scheduler.ex`, `apps/druzhok/lib/druzhok/instance_watcher.ex`, `apps/druzhok/lib/druzhok/runtime/open_claw.ex`, `runtime/zero_claw.ex`, `runtime/pico_claw.ex`, `runtime/null_claw.ex`, `apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex`, `apps/druzhok_web/lib/druzhok_web_web/channels/chat_socket.ex` (verify name with `ls apps/druzhok_web/lib/druzhok_web_web/channels/`), `services/sandbox-agent/` (whole dir), `docker-entrypoint.sh`, `workspace-template/` (the stale copy inside `v4/druzhok`, NOT the top-level one), `apps/druzhok/priv/translations.json`.
- Delete tests: `apps/druzhok/test/druzhok/sandbox_test.exs`, `apps/druzhok/test/druzhok/sandbox/`, `apps/druzhok/test/druzhok/instance/sup_test.exs`, `apps/druzhok/test/druzhok/supervision_test.exs`, `apps/druzhok/test/druzhok/instance_watcher_test.exs`.
- Modify: `apps/druzhok/lib/druzhok/application.ex`, `apps/druzhok/lib/druzhok/runtime.ex`, `apps/druzhok/lib/druzhok/instance_manager.ex`, `apps/druzhok/lib/druzhok/i18n.ex`, `apps/druzhok_web/lib/druzhok_web_web/endpoint.ex`, `apps/druzhok/test/druzhok/model_catalog_price_test.exs`, `apps/druzhok/test/druzhok/model_info_test.exs`, `apps/druzhok/test/druzhok/settings_test.exs`, `apps/druzhok_web/test/druzhok_web_web/llm_format_test.exs`, `apps/druzhok_web/test/druzhok_web_web/live/dashboard_live_test.exs`, `apps/druzhok/test/druzhok/runtime/hermes_test.exs`.

**Interfaces:**
- Produces: `Druzhok.Runtime.list/0` returns `%{"hermes" => Druzhok.Runtime.Hermes}` only. `Druzhok.Runtime.get/1` and `get/2` unchanged in shape.

- [ ] **Step 1: Confirm nothing references the modules being deleted**

Run from `v4/druzhok`:
```bash
grep -rn "Sandbox\.\|Druzhok.Sandbox\|Instance.Sup\|Druzhok.Scheduler\|InstanceWatcher\|ChatChannel\|ChatSocket\|Runtime.OpenClaw\|Runtime.ZeroClaw\|Runtime.PicoClaw\|Runtime.NullClaw\|InstanceDynSup" apps --include=*.ex --include=*.exs --include=*.heex | grep -v "^apps/druzhok/lib/druzhok/sandbox\|^apps/druzhok/lib/druzhok/runtime/\(open\|zero\|pico\|null\)_claw\|^apps/druzhok/lib/druzhok/instance/sup.ex\|^apps/druzhok/lib/druzhok/scheduler.ex\|^apps/druzhok/lib/druzhok/instance_watcher.ex\|channels/\|/test/"
```
Expected hits, and what to do with each:
- `application.ex:14` (`InstanceDynSup`) → remove in Step 3.
- `runtime.ex:34-38` (registry entries) → remove in Step 3.
- `instance_manager.ex` (`update_heartbeat/2` uses `Druzhok.Scheduler`) → delete that function in Step 3.
- `endpoint.ex` (`socket "/socket/chat"`) → remove in Step 3.
- `i18n.ex:79-80` (`sandbox_docker`, `sandbox_firecracker`) → remove in Step 3.
Anything else: stop and report.

- [ ] **Step 2: Delete the files**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
git rm -r -q apps/druzhok/lib/druzhok/sandbox.ex apps/druzhok/lib/druzhok/sandbox \
  apps/druzhok/lib/druzhok/instance/sup.ex apps/druzhok/lib/druzhok/scheduler.ex \
  apps/druzhok/lib/druzhok/instance_watcher.ex \
  apps/druzhok/lib/druzhok/runtime/open_claw.ex apps/druzhok/lib/druzhok/runtime/zero_claw.ex \
  apps/druzhok/lib/druzhok/runtime/pico_claw.ex apps/druzhok/lib/druzhok/runtime/null_claw.ex \
  apps/druzhok_web/lib/druzhok_web_web/channels \
  services/sandbox-agent docker-entrypoint.sh workspace-template apps/druzhok/priv/translations.json \
  apps/druzhok/test/druzhok/sandbox_test.exs apps/druzhok/test/druzhok/sandbox \
  apps/druzhok/test/druzhok/instance/sup_test.exs apps/druzhok/test/druzhok/supervision_test.exs \
  apps/druzhok/test/druzhok/instance_watcher_test.exs
rmdir apps/druzhok/lib/druzhok/instance apps/druzhok/test/druzhok/instance 2>/dev/null; true
```

- [ ] **Step 3: Remove the references**

`apps/druzhok/lib/druzhok/application.ex` — children become:
```elixir
    children = [
      Druzhok.Repo,
      {Registry, keys: :unique, name: Druzhok.Registry},
      {Finch, name: Druzhok.Finch, pools: finch_pools()},
      {Finch, name: Druzhok.LocalFinch},
      Druzhok.HealthMonitor,
      Druzhok.ManagerBot
    ]
```

`apps/druzhok/lib/druzhok/runtime.ex` — replace the `@runtimes` map and moduledoc:
```elixir
  @moduledoc """
  Behaviour for bot runtime adapters. Hermes is the only runtime; the
  behaviour stays so config/workspace generation is cleanly separated
  from process control (see `Druzhok.Host`).
  """
  ...
  @runtimes %{"hermes" => Druzhok.Runtime.Hermes}
```

`apps/druzhok/lib/druzhok/instance_manager.ex` — delete `update_heartbeat/2` entirely.

`apps/druzhok_web/lib/druzhok_web_web/endpoint.ex` — delete the `socket "/socket/chat", ...` block (keep `/live`).

`apps/druzhok/lib/druzhok/i18n.ex` — delete the `sandbox_docker:` and `sandbox_firecracker:` entries (and `sandbox_local:` if present).

- [ ] **Step 4: Compile with warnings as errors to catch leftovers**

Run: `mix compile --force --warnings-as-errors 2>&1 | tail -20`
Expected: compiles. If an `undefined function`/`module` warning points at one of the deleted modules, remove that call site too (it was dead).

- [ ] **Step 5: Fix the six stale tests**

`apps/druzhok/test/druzhok/model_catalog_price_test.exs` — the catalog migrated from `xiaomi/mimo-v2-pro` to `xiaomi/mimo-v2.5-pro`. Check the real price first:
```bash
grep -n "mimo" apps/druzhok/lib/druzhok/model_catalog.ex apps/druzhok/priv/repo/seeds.exs | head
```
Replace the model id in the assertion with `xiaomi/mimo-v2.5-pro` and the expected `%{input: …, output: …}` with the values from the catalog.

`apps/druzhok_web/test/druzhok_web_web/llm_format_test.exs` — same substitution in the `extract_cost_cents/2 falls back to ModelCatalog price` test.

`apps/druzhok/test/druzhok/model_info_test.exs` — test `context_window matches after stripping provider prefix` expects 64000, code returns 32000 for `nebius/deepseek-ai/<id>`. Read `apps/druzhok/lib/druzhok/model_info.ex`; the table value is authoritative — change the test expectation to the table value.

`apps/druzhok/test/druzhok/settings_test.exs` — `api_url returns nebius URL for unknown provider` gets `nil` because `config :druzhok, :nebius_api_url` is only set in `runtime.exs` (not loaded in test). Add to `config/test.exs`:
```elixir
config :druzhok,
  nebius_api_url: "https://api.tokenfactory.us-central1.nebius.com/v1",
  openrouter_api_url: "https://openrouter.ai/api/v1",
  anthropic_api_url: "https://api.anthropic.com"
```

`apps/druzhok/test/druzhok/runtime/hermes_test.exs` — delete the two tests that call `Hermes.sync_translations_file/1` / assert `translations.json` (feature removed 2026-05-24).

`apps/druzhok_web/test/druzhok_web_web/live/dashboard_live_test.exs` — three copy assertions are stale. Find the real strings:
```bash
grep -n "instances yet\|Instance name\|Name is required\|placeholder=" apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex | head
```
Update the three `assert html =~ "…"` lines to the strings actually rendered (the failing output showed `Name is required` for the empty-name case).

- [ ] **Step 6: Run the full suite**

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures` in both apps.

- [ ] **Step 7: Commit**

Use `/my-commit`. Intended message: `remove dead sandbox/scheduler/multi-runtime/chat-channel code, fix stale tests`.

---

### Task 2: Remove Honcho

**Files:**
- Delete: `apps/druzhok/lib/druzhok/honcho_jwt.ex`, `apps/druzhok/test/druzhok/honcho_jwt_test.exs`.
- Create: `apps/druzhok/priv/repo/migrations/20260823000001_drop_honcho_system_tenant.exs`.
- Modify: `apps/druzhok/lib/druzhok/runtime/hermes.ex`, `apps/druzhok/lib/druzhok/instance.ex`, `apps/druzhok/lib/druzhok/instance_manager.ex:38-48`, `apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex:247-262,441-452`, `apps/druzhok/test/druzhok/runtime/hermes_test.exs`, `apps/druzhok/mix.exs` (drop `:joken` if `HonchoJwt` was its only user — check with `grep -rn Joken apps`).

**Interfaces:**
- Produces: `Druzhok.Runtime.Hermes.sync_config/2` no longer writes `honcho.json`; the `memory:` block is always `provider: builtin`, `memory_enabled: true`, `user_profile_enabled: true`. `memory_section/0` (arity 0) returns the builtin text.

- [ ] **Step 1: Write the failing tests (replace the honcho describe block)**

In `apps/druzhok/test/druzhok/runtime/hermes_test.exs`, delete the whole `describe "sync_config/2 — honcho.json"` block (lines ~153-348) and add:

```elixir
  describe "sync_config/2 — memory block" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hermes-mem-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "workspace"))
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "forces builtin provider and legacy memory on, keeps char limits", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"
      memory:
        provider: honcho
        memory_enabled: false
        user_profile_enabled: false
        memory_char_limit: 999
      """)

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  provider: builtin$/m
      assert content =~ ~r/^  memory_enabled: true$/m
      assert content =~ ~r/^  user_profile_enabled: true$/m
      assert content =~ ~r/^  memory_char_limit: 999$/m
    end

    test "removes a stale honcho.json", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      File.write!(Path.join(tmp_dir, "honcho.json"), "{}")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      refute File.exists?(Path.join(tmp_dir, "honcho.json"))
    end

    test "AGENTS.md memory section is the builtin text", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), "model:\n  default: \"x\"\n")
      File.write!(Path.join([tmp_dir, "workspace", "AGENTS.md"]), "# Agent\n\n## Память\n\nhoncho stuff\n\n## Other\n")
      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k"}, tmp_dir)
      agents = File.read!(Path.join([tmp_dir, "workspace", "AGENTS.md"]))
      refute agents =~ "honcho"
      assert agents =~ "## Память"
      assert agents =~ "## Other"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs 2>&1 | tail -8`
Expected: the first test fails (`provider: honcho` survives because `memory_provider` is read from the instance map and defaults to builtin — actually check: it may pass already; the second fails only if `honcho.json` removal is tied to `memory_provider`). At least the AGENTS.md test and compile of the module must be exercised; proceed regardless.

- [ ] **Step 3: Strip honcho from `hermes.ex`**

In `apps/druzhok/lib/druzhok/runtime/hermes.ex`:
- In `sync_config/2` replace `sync_honcho_config(instance, data_root)` with `_ = File.rm(Path.join(data_root, "honcho.json"))`.
- Delete `@honcho_filename`, `sync_honcho_config/2`, `honcho_config/3`, `honcho_workspace/1`, `ensure_honcho_token!/2` (lines ~340-410).
- Replace `sync_memory_block/2` body:
```elixir
  defp sync_memory_block(content, _instance) do
    sync_yaml_block(content, "memory",
      upsert: fn body ->
        body
        |> upsert_indented_line("provider", "builtin")
        |> upsert_indented_line("memory_enabled", "true")
        |> upsert_indented_line("user_profile_enabled", "true")
      end,
      default: default_memory_block()
    )
  end
```
and `default_memory_block/0`:
```elixir
  defp default_memory_block do
    """
    memory:
      provider: builtin
      memory_enabled: true
      user_profile_enabled: true
      memory_char_limit: 2200
      user_char_limit: 1375\
    """
  end
```
- `sync_memory_section/2`: replace `provider = …; new_section = memory_section(provider)` with `new_section = memory_section()`. Delete `memory_section("honcho")`; rename `memory_section(_other)` to `memory_section()` (arity 0).
- In `build_config_yaml/1` delete the `memory_provider = …` line and hardcode `provider: builtin` in the `memory:` block.
- Delete the `alias Druzhok.{BotManager, Instance}` `Instance` part if no longer used (`grep -n "Instance\." apps/druzhok/lib/druzhok/runtime/hermes.ex`).

- [ ] **Step 4: Strip honcho from schema, manager, UI, deps**

`apps/druzhok/lib/druzhok/instance.ex` — remove `memory_provider`, `honcho_workspace`, `honcho_token` from the `schema` and the `cast` list. (Columns remain in SQLite; Ecto ignores them.)

`apps/druzhok/lib/druzhok/instance_manager.ex` — keep the `where: i.bot_runtime != "system"` filter (harmless, and the migration below removes the row) but reword the comment to `# Exclude legacy synthetic "system" rows.`

`apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — delete the memory-provider `<form>` (lines ~247-262, the whole block that renders the select and the honcho workspace input) and the two handlers `set_memory_provider` and `update_honcho_workspace`.

Migration `apps/druzhok/priv/repo/migrations/20260823000001_drop_honcho_system_tenant.exs`:
```elixir
defmodule Druzhok.Repo.Migrations.DropHonchoSystemTenant do
  use Ecto.Migration

  def up do
    execute "DELETE FROM instances WHERE bot_runtime = 'system'"
  end

  def down, do: :ok
end
```

Delete `apps/druzhok/lib/druzhok/honcho_jwt.ex` and its test. If `grep -rn "Joken" apps --include=*.ex` returns nothing, remove `{:joken, "~> 2.6"}` from `apps/druzhok/mix.exs` and run `mix deps.unlock --unused`.

- [ ] **Step 5: Migrate test DB, run suite**

```bash
MIX_ENV=test mix ecto.migrate 2>&1 | tail -2
mix compile --warnings-as-errors 2>&1 | tail -5
mix test 2>&1 | tail -5
```
Expected: `0 failures`.

- [ ] **Step 6: Commit**

`/my-commit` — `drop honcho memory backend (builtin only)`.

---

### Task 3: `Druzhok.Host` behaviour and `Host.Process` (dev/test implementation)

**Files:**
- Create: `apps/druzhok/lib/druzhok/host.ex`, `apps/druzhok/lib/druzhok/host/process.ex`, `apps/druzhok/test/support/fake_hermes.sh`, `apps/druzhok/test/druzhok/host/process_test.exs`.
- Modify: `apps/druzhok/lib/druzhok/application.ex` (add `Druzhok.Host.ProcessSup`), `apps/druzhok/mix.exs` (`elixirc_paths` for `test/support`), `config/config.exs`, `config/test.exs`.

**Interfaces:**
- Produces:
```elixir
defmodule Druzhok.Host do
  @type name :: String.t()
  @type status :: :active | :activating | :inactive | :failed | :unknown
  @callback start(name, env :: %{String.t() => String.t()}, data_root :: String.t()) :: :ok | {:error, term()}
  @callback stop(name) :: :ok
  @callback destroy(name) :: :ok
  @callback status(name) :: status
  @callback stats(name) :: %{mem_bytes: non_neg_integer(), cpu_usec: non_neg_integer()} | nil
  @callback exec(name, args :: [String.t()]) :: {String.t(), integer()}
  @callback logs(name, lines :: pos_integer()) :: String.t()
  def impl, do: Application.get_env(:druzhok, :host, Druzhok.Host.Process)
  # plus delegating wrappers: Druzhok.Host.start/3, stop/1, destroy/1, status/1, stats/1, exec/2, logs/2
  def valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,30}$/, name)
end
```
- `Druzhok.Host.Process` reads the binary from `Application.get_env(:druzhok, :hermes_bin)` (default `"hermes"`), runs `[bin, "gateway", "run"]` with `cd: data_root`, env = given map merged with `HERMES_HOME => data_root`.

- [ ] **Step 1: Test support stub**

`apps/druzhok/test/support/fake_hermes.sh` (chmod +x):
```bash
#!/usr/bin/env bash
# Stand-in for `hermes gateway run` in tests. Prints its env, then idles.
echo "fake-hermes started args=$* HERMES_HOME=$HERMES_HOME TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN"
if [ -n "$FAKE_HERMES_EXIT" ]; then exit "$FAKE_HERMES_EXIT"; fi
while true; do sleep 1; done
```
`apps/druzhok/mix.exs`: add `elixirc_paths: elixirc_paths(Mix.env())` to `project/0` and
```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
```
(Only needed if you add `.ex` helpers; the `.sh` stubs are referenced by path. Add it anyway — Task 4 adds an `.ex`.)

`config/config.exs`:
```elixir
config :druzhok,
  ecto_repos: [Druzhok.Repo],
  host: Druzhok.Host.Process,
  hermes_bin: System.get_env("HERMES_BIN") || "hermes"
```
`config/test.exs`:
```elixir
config :druzhok,
  host: Druzhok.Host.Process,
  hermes_bin: Path.expand("../apps/druzhok/test/support/fake_hermes.sh", __DIR__)
```

- [ ] **Step 2: Write the failing tests**

`apps/druzhok/test/druzhok/host/process_test.exs`:
```elixir
defmodule Druzhok.Host.ProcessTest do
  use ExUnit.Case, async: false

  alias Druzhok.Host.Process, as: HostProcess

  setup do
    name = "t-#{System.unique_integer([:positive])}"
    data_root = Path.join(System.tmp_dir!(), "host-#{name}")
    File.mkdir_p!(data_root)
    on_exit(fn -> HostProcess.destroy(name); File.rm_rf!(data_root) end)
    %{name: name, data_root: data_root}
  end

  test "start → active, logs show env, stop → inactive", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{"TELEGRAM_BOT_TOKEN" => "tok123"}, root)
    assert HostProcess.status(name) == :active
    Process.sleep(200)
    logs = HostProcess.logs(name, 10)
    assert logs =~ "fake-hermes started args=gateway run"
    assert logs =~ "HERMES_HOME=#{root}"
    assert logs =~ "TELEGRAM_BOT_TOKEN=tok123"
    assert %{mem_bytes: m, cpu_usec: _} = HostProcess.stats(name)
    assert m > 0
    assert :ok = HostProcess.stop(name)
    assert HostProcess.status(name) == :inactive
  end

  test "start is idempotent", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{}, root)
    assert :ok = HostProcess.start(name, %{}, root)
    assert HostProcess.status(name) == :active
  end

  test "exited process reports :failed", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{"FAKE_HERMES_EXIT" => "3"}, root)
    Process.sleep(300)
    assert HostProcess.status(name) == :failed
  end

  test "unknown name", _ do
    assert HostProcess.status("nope") == :unknown
    assert HostProcess.stop("nope") == :ok
    assert HostProcess.logs("nope", 5) == ""
    assert HostProcess.stats("nope") == nil
  end

  test "exec runs a command with HERMES_HOME set", %{name: name, data_root: root} do
    assert :ok = HostProcess.start(name, %{}, root)
    assert {out, 0} = HostProcess.exec(name, ["sh", "-c", "echo $HERMES_HOME"])
    assert String.trim(out) == root
  end

  test "rejects invalid names" do
    assert {:error, :invalid_name} = HostProcess.start("Bad Name", %{}, "/tmp")
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `mix test apps/druzhok/test/druzhok/host/process_test.exs 2>&1 | tail -5`
Expected: compile error, `Druzhok.Host.Process` undefined.

- [ ] **Step 4: Implement `Druzhok.Host`**

`apps/druzhok/lib/druzhok/host.ex`:
```elixir
defmodule Druzhok.Host do
  @moduledoc """
  Process-control backend for bots. `Druzhok.Host.Systemd` in production
  (one systemd unit + Linux user per bot via `druzhok-ctl`), `Druzhok.Host.Process`
  for local development and tests (plain OS process, no isolation).

  `BotManager` owns *what* to run (env, config files, DB state); `Host` owns
  *how* it runs.
  """

  @type name :: String.t()
  @type status :: :active | :activating | :inactive | :failed | :unknown
  @type stats :: %{mem_bytes: non_neg_integer(), cpu_usec: non_neg_integer()} | nil

  @callback start(name, env :: %{String.t() => String.t()}, data_root :: String.t()) :: :ok | {:error, term()}
  @callback stop(name) :: :ok
  @callback destroy(name) :: :ok
  @callback status(name) :: status
  @callback stats(name) :: stats
  @callback exec(name, args :: [String.t()]) :: {String.t(), integer()}
  @callback logs(name, lines :: pos_integer()) :: String.t()

  @name_re ~r/^[a-z0-9][a-z0-9-]{0,30}$/

  def impl, do: Application.get_env(:druzhok, :host, Druzhok.Host.Process)

  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_re, name)
  def valid_name?(_), do: false

  def start(name, env, data_root), do: impl().start(name, env, data_root)
  def stop(name), do: impl().stop(name)
  def destroy(name), do: impl().destroy(name)
  def status(name), do: impl().status(name)
  def stats(name), do: impl().stats(name)
  def exec(name, args), do: impl().exec(name, args)
  def logs(name, lines \\ 200), do: impl().logs(name, lines)
end
```

- [ ] **Step 5: Implement `Druzhok.Host.Process`**

`apps/druzhok/lib/druzhok/host/process.ex`:
```elixir
defmodule Druzhok.Host.Process do
  @moduledoc """
  Dev/test `Druzhok.Host`: runs `hermes gateway run` as a child OS process
  (Erlang port) per bot. No isolation whatsoever — never use in production.
  """
  @behaviour Druzhok.Host

  use GenServer
  require Logger

  @ring 500

  # --- Druzhok.Host callbacks -------------------------------------------------

  @impl Druzhok.Host
  def start(name, env, data_root) do
    cond do
      not Druzhok.Host.valid_name?(name) -> {:error, :invalid_name}
      lookup(name) != nil -> :ok
      true ->
        spec = {__MODULE__, %{name: name, env: env, data_root: data_root}}
        case DynamicSupervisor.start_child(Druzhok.Host.ProcessSup, spec) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl Druzhok.Host
  def stop(name) do
    case lookup(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 10_000); :ok
    end
  end

  @impl Druzhok.Host
  def destroy(name), do: stop(name)

  @impl Druzhok.Host
  def status(name) do
    case lookup(name) do
      nil -> :unknown
      pid -> GenServer.call(pid, :status)
    end
  end

  @impl Druzhok.Host
  def stats(name) do
    with pid when pid != nil <- lookup(name),
         {:ok, os_pid} <- GenServer.call(pid, :os_pid),
         {out, 0} <- System.cmd("ps", ["-o", "rss=,time=", "-p", to_string(os_pid)]),
         [rss_kb, time] <- String.split(String.trim(out)) do
      %{mem_bytes: String.to_integer(rss_kb) * 1024, cpu_usec: parse_ps_time(time)}
    else
      _ -> nil
    end
  end

  @impl Druzhok.Host
  def exec(name, args) do
    case lookup(name) do
      nil -> {"no such bot", 1}
      pid ->
        %{env: env, data_root: root} = GenServer.call(pid, :config)
        [cmd | rest] = args
        System.cmd(cmd, rest, env: Map.to_list(Map.put(env, "HERMES_HOME", root)), cd: root, stderr_to_stdout: true)
    end
  end

  @impl Druzhok.Host
  def logs(name, lines) do
    case lookup(name) do
      nil -> ""
      pid -> pid |> GenServer.call(:logs) |> Enum.take(-lines) |> Enum.join("\n")
    end
  end

  # --- GenServer ---------------------------------------------------------------

  def child_spec(cfg) do
    %{id: {__MODULE__, cfg.name}, start: {__MODULE__, :start_link, [cfg]}, restart: :temporary}
  end

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: via(cfg.name))

  @impl GenServer
  def init(%{name: name, env: env, data_root: root}) do
    Process.flag(:trap_exit, true)
    bin = Application.get_env(:druzhok, :hermes_bin, "hermes")
    full_env = env |> Map.put("HERMES_HOME", root) |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, System.find_executable(bin) || bin},
        [:binary, :exit_status, :stderr_to_stdout, {:line, 4096},
         {:args, ["gateway", "run"]}, {:cd, root}, {:env, full_env}])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Logger.info("Host.Process started #{name} (pid #{os_pid})")
    {:ok, %{name: name, env: env, data_root: root, port: port, os_pid: os_pid, status: :active, logs: []}}
  end

  @impl GenServer
  def handle_call(:status, _from, s), do: {:reply, s.status, s}
  def handle_call(:os_pid, _from, %{status: :active} = s), do: {:reply, {:ok, s.os_pid}, s}
  def handle_call(:os_pid, _from, s), do: {:reply, :error, s}
  def handle_call(:config, _from, s), do: {:reply, %{env: s.env, data_root: s.data_root}, s}
  def handle_call(:logs, _from, s), do: {:reply, Enum.reverse(s.logs), s}

  @impl GenServer
  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = s) do
    {:noreply, %{s | logs: Enum.take([line | s.logs], @ring)}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    Logger.warning("Host.Process #{s.name} exited with #{code}")
    {:noreply, %{s | status: if(code == 0, do: :inactive, else: :failed), port: nil}}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl GenServer
  def terminate(_reason, %{port: nil} = s), do: {:noreply, s}
  def terminate(_reason, s) do
    # Port.close only closes the pipe; kill the OS process group explicitly.
    System.cmd("kill", ["-TERM", to_string(s.os_pid)])
    try do Port.close(s.port) catch _, _ -> :ok end
    :ok
  end

  # --- helpers -----------------------------------------------------------------

  defp via(name), do: {:via, Registry, {Druzhok.Registry, {name, :host_process}}}

  defp lookup(name) do
    case Registry.lookup(Druzhok.Registry, {name, :host_process}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # "MM:SS.ss" or "HH:MM:SS" → microseconds
  defp parse_ps_time(str) do
    parts = str |> String.split(":") |> Enum.map(&(Float.parse(&1) |> elem(0)))
    secs =
      case parts do
        [h, m, s] -> h * 3600 + m * 60 + s
        [m, s] -> m * 60 + s
        [s] -> s
        _ -> 0.0
      end
    round(secs * 1_000_000)
  end
end
```
Note on `status/1` after a clean `stop/1`: the GenServer is gone, so `lookup/1` is nil → `:unknown`. The test expects `:inactive` after stop. Make `stop/1` return `:ok` and `status/1` return `:inactive` when the name is valid but not running, `:unknown` only for invalid names:
```elixir
  def status(name) do
    case lookup(name) do
      nil -> if Druzhok.Host.valid_name?(name), do: :inactive, else: :unknown
      pid -> GenServer.call(pid, :status)
    end
  end
```
and change the `"unknown name"` test's first assertion to `assert HostProcess.status("nope") == :inactive` and add `assert HostProcess.status("Bad Name") == :unknown`.

`apps/druzhok/lib/druzhok/application.ex` — add `{DynamicSupervisor, name: Druzhok.Host.ProcessSup, strategy: :one_for_one}` after the Registry.

- [ ] **Step 6: Run tests**

Run: `mix test apps/druzhok/test/druzhok/host/process_test.exs 2>&1 | tail -8`
Expected: 6 tests, 0 failures. If `exec` fails on macOS because `sh` isn't found via `System.cmd`, use `System.find_executable("sh")`.

- [ ] **Step 7: Commit**

`/my-commit` — `add Druzhok.Host behaviour with Process backend for dev/test`.

---

### Task 4: `Host.Systemd` (production implementation)

**Files:**
- Create: `apps/druzhok/lib/druzhok/host/systemd.ex`, `apps/druzhok/test/support/fake_druzhok_ctl.sh`, `apps/druzhok/test/druzhok/host/systemd_test.exs`.
- Modify: `config/runtime.exs`.

**Interfaces:**
- Consumes: `Druzhok.Host` callbacks (Task 3).
- Produces: `Druzhok.Host.Systemd` shelling out to `Application.get_env(:druzhok, :druzhok_ctl)` (default `["sudo", "-n", "/usr/local/sbin/druzhok-ctl"]`). Env serialisation: `Druzhok.Host.Systemd.env_file(map) :: String.t()` — one `KEY="value"` per line, `"` and `\` backslash-escaped, `$` left as-is (systemd does not expand it), sorted by key, trailing newline.
- The real `druzhok-ctl` contract (ops plan) is: `create <name>` (env on stdin), `update-env <name>` (env on stdin), `start|stop|restart|destroy <name>`, `status <name>` → one word, `stats <name>` → `<mem_bytes>|<cpu_usec>`, `logs <name> <n>`, `exec <name> <args…>`. All commands exit non-zero with a message on stderr on failure.

- [ ] **Step 1: Fake ctl script**

`apps/druzhok/test/support/fake_druzhok_ctl.sh` (chmod +x):
```bash
#!/usr/bin/env bash
# Records every invocation to $FAKE_CTL_LOG and answers like druzhok-ctl.
log="${FAKE_CTL_LOG:?}"
cmd="$1"; name="$2"; shift 2
stdin=""
case "$cmd" in create|update-env) stdin="$(cat)";; esac
printf '%s\t%s\t%s\t%s\n' "$cmd" "$name" "$*" "$(printf '%s' "$stdin" | base64 | tr -d '\n')" >> "$log"
state="${FAKE_CTL_STATE:-/tmp/fake-ctl-state-$name}"
case "$cmd" in
  create)      echo created > "$state"; exit 0;;
  update-env)  exit 0;;
  start)       echo active > "$state"; exit 0;;
  stop)        echo inactive > "$state"; exit 0;;
  restart)     echo active > "$state"; exit 0;;
  destroy)     rm -f "$state"; exit 0;;
  status)      if [ -f "$state" ]; then cat "$state"; else echo unknown; fi; exit 0;;
  stats)       echo "123456|7890"; exit 0;;
  logs)        echo "line1"; echo "line2"; exit 0;;
  exec)        exec "$@";;
  *)           echo "unknown command $cmd" >&2; exit 2;;
esac
```

- [ ] **Step 2: Failing tests**

`apps/druzhok/test/druzhok/host/systemd_test.exs`:
```elixir
defmodule Druzhok.Host.SystemdTest do
  use ExUnit.Case, async: false

  alias Druzhok.Host.Systemd

  @ctl Path.expand("../../support/fake_druzhok_ctl.sh", __DIR__)

  setup do
    log = Path.join(System.tmp_dir!(), "fake-ctl-#{System.unique_integer([:positive])}.log")
    state = log <> ".state"
    System.put_env("FAKE_CTL_LOG", log)
    System.put_env("FAKE_CTL_STATE", state)
    prev = Application.get_env(:druzhok, :druzhok_ctl)
    Application.put_env(:druzhok, :druzhok_ctl, [@ctl])
    on_exit(fn ->
      Application.put_env(:druzhok, :druzhok_ctl, prev)
      File.rm(log); File.rm(state)
    end)
    %{log: log}
  end

  defp calls(log) do
    log |> File.read!() |> String.split("\n", trim: true)
    |> Enum.map(fn l ->
      [cmd, name, args, stdin] = String.split(l, "\t")
      {cmd, name, args, Base.decode64!(stdin)}
    end)
  end

  test "env_file serialises sorted, quoted, escaped" do
    assert Systemd.env_file(%{"B" => ~s(say "hi" \\ $X), "A" => "1"}) ==
             ~s(A="1"\nB="say \\"hi\\" \\\\ $X"\n)
  end

  test "start creates (first time), updates env, starts; second start skips create", %{log: log} do
    assert :ok = Systemd.start("bot-a", %{"K" => "v"}, "/data/tenants/bot-a")
    assert [{"status", "bot-a", _, _}, {"create", "bot-a", _, env}, {"start", "bot-a", _, _}] = calls(log)
    assert env == ~s(K="v"\n)
    File.write!(log, "")
    assert :ok = Systemd.start("bot-a", %{"K" => "v2"}, "/data/tenants/bot-a")
    assert [{"status", _, _, _}, {"update-env", "bot-a", _, ~s(K="v2"\n)}, {"start", _, _, _}] = calls(log)
  end

  test "status maps words to atoms", _ do
    assert Systemd.status("bot-z") == :unknown
    assert :ok = Systemd.start("bot-z", %{}, "/x")
    assert Systemd.status("bot-z") == :active
    assert :ok = Systemd.stop("bot-z")
    assert Systemd.status("bot-z") == :inactive
  end

  test "stats parses mem|cpu" do
    assert Systemd.stats("bot-a") == %{mem_bytes: 123_456, cpu_usec: 7_890}
  end

  test "logs and exec pass through" do
    assert Systemd.logs("bot-a", 2) == "line1\nline2"
    assert {"hello\n", 0} = Systemd.exec("bot-a", ["echo", "hello"])
  end

  test "destroy", %{log: log} do
    assert :ok = Systemd.destroy("bot-a")
    assert [{"destroy", "bot-a", _, _}] = calls(log)
  end

  test "invalid name never reaches the helper", %{log: log} do
    assert {:error, :invalid_name} = Systemd.start("../etc", %{}, "/x")
    assert Systemd.status("X Y") == :unknown
    refute File.exists?(log)
  end
end
```

- [ ] **Step 3: Run, expect failure**

Run: `mix test apps/druzhok/test/druzhok/host/systemd_test.exs 2>&1 | tail -5`
Expected: `Druzhok.Host.Systemd` undefined.

- [ ] **Step 4: Implement**

`apps/druzhok/lib/druzhok/host/systemd.ex`:
```elixir
defmodule Druzhok.Host.Systemd do
  @moduledoc """
  Production `Druzhok.Host`: every bot is a Linux user `bot-<name>` running the
  template unit `hermes@<name>.service`. All privileged operations go through
  the root helper `druzhok-ctl` (see `ops/druzhok-ctl`), invoked via sudo.
  Secrets are passed on stdin as an `EnvironmentFile`, never on argv.
  """
  @behaviour Druzhok.Host
  require Logger

  @impl true
  def start(name, env, _data_root) do
    with :ok <- check_name(name) do
      first_cmd = if status(name) == :unknown, do: "create", else: "update-env"
      with {_, 0} <- ctl([first_cmd, name], input: env_file(env)),
           {_, 0} <- ctl(["start", name]) do
        :ok
      else
        {out, code} -> {:error, {first_cmd_or_start(out), code, String.trim(out)}}
        error -> error
      end
    end
  end

  defp first_cmd_or_start(_out), do: :druzhok_ctl

  @impl true
  def stop(name) do
    with :ok <- check_name(name), do: (ctl(["stop", name]); :ok)
  end

  @impl true
  def destroy(name) do
    with :ok <- check_name(name), do: (ctl(["destroy", name]); :ok)
  end

  @impl true
  def status(name) do
    with :ok <- check_name(name),
         {out, 0} <- ctl(["status", name]) do
      case String.trim(out) do
        "active" -> :active
        "activating" -> :activating
        "inactive" -> :inactive
        "failed" -> :failed
        "created" -> :inactive
        _ -> :unknown
      end
    else
      _ -> :unknown
    end
  end

  @impl true
  def stats(name) do
    with :ok <- check_name(name),
         {out, 0} <- ctl(["stats", name]),
         [mem, cpu] <- out |> String.trim() |> String.split("|"),
         {m, ""} <- Integer.parse(mem),
         {c, ""} <- Integer.parse(cpu) do
      %{mem_bytes: m, cpu_usec: c}
    else
      _ -> nil
    end
  end

  @impl true
  def exec(name, args) do
    case check_name(name) do
      :ok -> ctl(["exec", name | args])
      {:error, _} -> {"invalid bot name", 1}
    end
  end

  @impl true
  def logs(name, lines) do
    with :ok <- check_name(name), {out, 0} <- ctl(["logs", name, to_string(lines)]) do
      String.trim_trailing(out)
    else
      _ -> ""
    end
  end

  @doc "Serialise env as a systemd EnvironmentFile (sorted, double-quoted, escaped)."
  def env_file(env) do
    env
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} ->
      escaped = v |> to_string() |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      ~s(#{k}="#{escaped}"\n)
    end)
    |> Enum.join()
  end

  # --- helpers ---------------------------------------------------------------

  defp check_name(name), do: if(Druzhok.Host.valid_name?(name), do: :ok, else: {:error, :invalid_name})

  defp ctl(args, opts \\ []) do
    [bin | prefix] = Application.get_env(:druzhok, :druzhok_ctl, ["sudo", "-n", "/usr/local/sbin/druzhok-ctl"])
    input = Keyword.get(opts, :input)

    if input do
      # System.cmd has no stdin option; use a port with stdin piping.
      port = Port.open({:spawn_executable, System.find_executable(bin) || bin},
        [:binary, :exit_status, :stderr_to_stdout, :use_stdio, {:args, prefix ++ args}])
      Port.command(port, input)
      Port.close_stdin(port)
      collect(port, "")
    else
      System.cmd(bin, prefix ++ args, stderr_to_stdout: true)
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, code}} -> {acc, code}
    after
      30_000 -> Port.close(port); {acc <> "\n(timeout)", 124}
    end
  end
end
```
`Port.close_stdin/1` does not exist in Elixir; send EOF by wrapping the command: replace the `if input` branch with
```elixir
      {out, code} =
        System.cmd("sh", ["-c", ~s(exec "$@"), "sh", bin | prefix ++ args],
          stderr_to_stdout: true, env: [], into: "")
```
is also stdin-less. The reliable approach: write `input` to a temp file (0600, in `System.tmp_dir!()`) and run `sh -c 'exec "$0" "$@" < "$TMP"' bin args…`, deleting the file in `after`. Implement `ctl/2` as:
```elixir
  defp ctl(args, opts \\ []) do
    [bin | prefix] = Application.get_env(:druzhok, :druzhok_ctl, ["sudo", "-n", "/usr/local/sbin/druzhok-ctl"])

    case Keyword.get(opts, :input) do
      nil ->
        System.cmd(bin, prefix ++ args, stderr_to_stdout: true)

      input ->
        tmp = Path.join(System.tmp_dir!(), "druzhok-env-#{System.unique_integer([:positive])}")
        File.write!(tmp, input)
        File.chmod!(tmp, 0o600)
        try do
          System.cmd("sh", ["-c", ~s(exec "$0" "$@" < "#{tmp}"), bin | prefix ++ args], stderr_to_stdout: true)
        after
          File.rm(tmp)
        end
    end
  end
```
and simplify `start/3`'s error clause to `{out, code} -> {:error, {:druzhok_ctl, code, String.trim(out)}}` (drop `first_cmd_or_start/1`).

`config/runtime.exs` — add inside the existing `config :druzhok, …` block (or a new one):
```elixir
config :druzhok,
  host: (if System.get_env("DRUZHOK_HOST") == "systemd", do: Druzhok.Host.Systemd, else: Druzhok.Host.Process),
  druzhok_ctl: ["sudo", "-n", "/usr/local/sbin/druzhok-ctl"]
```

- [ ] **Step 5: Run tests**

Run: `mix test apps/druzhok/test/druzhok/host/ 2>&1 | tail -5`
Expected: all pass. The `"status maps words"` test relies on `FAKE_CTL_STATE` being a single file shared across names within one test — fine since each test uses one name.

- [ ] **Step 6: Commit**

`/my-commit` — `add Host.Systemd backend driving druzhok-ctl`.

---

### Task 5: Wire `BotManager`, `Runtime`, `HealthMonitor` and the dashboard to `Host`

**Files:**
- Modify: `apps/druzhok/lib/druzhok/bot_manager.ex`, `apps/druzhok/lib/druzhok/runtime.ex`, `apps/druzhok/lib/druzhok/runtime/hermes.ex`, `apps/druzhok/lib/druzhok/health_monitor.ex`, `apps/druzhok/lib/druzhok/instance_manager.ex`, `apps/druzhok/lib/druzhok/instance.ex`, `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex:827-853`, `apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex:562-570`, `apps/druzhok/test/druzhok/runtime/hermes_test.exs`, `apps/druzhok/test/druzhok/bot_manager_test.exs`.
- Delete: `apps/druzhok/lib/druzhok/log_watcher.ex`, `apps/druzhok/lib/druzhok/log_port.ex`, `apps/druzhok/test/druzhok/log_port_test.exs`.

**Interfaces:**
- Consumes: `Druzhok.Host.*` (Tasks 3–4).
- Produces:
  - `Druzhok.Runtime` callbacks: `env_vars/1`, `workspace_files/1`, `sync_config/2` (optional), `data_root/1`, `file_browser_root/1`, `post_start/1`, `supports_feature?/1`, `read_allowed_users/1`, `add_allowed_user/2`, `remove_allowed_user/2`, `clear_sessions/1`. Removed: `docker_image/0`, `gateway_command/0`, `data_mount_path/0`, `parse_log_rejection/1`.
  - `Druzhok.Runtime.Hermes.data_root(instance) :: String.t()` = `Path.dirname(instance.workspace)`.
  - `Druzhok.BotManager.status(name) :: String.t()` returns `"active" | "activating" | "inactive" | "failed" | "unknown"` (string, for the existing LiveView templates that compare to `"running"` — see Step 6).
  - `Druzhok.BotManager.stats(name) :: %{mem: String.t(), mem_bytes: integer, cpu: String.t(), net: String.t()} | nil` (same shape the dashboard renders today).
  - `Druzhok.BotManager.exec(name, args)` (no `:user` option).
  - `Druzhok.BotManager.logs(name, lines \\ 200)`.

- [ ] **Step 1: Update hermes tests first**

In `apps/druzhok/test/druzhok/runtime/hermes_test.exs`:
- Replace test `"sets HERMES_HOME to /opt/data"` with:
```elixir
    test "HERMES_HOME and MESSAGING_CWD derive from instance.workspace" do
      env = Hermes.env_vars(%{workspace: "/data/tenants/b/workspace", tenant_key: "k"})
      assert env["HERMES_HOME"] == "/data/tenants/b"
      assert env["MESSAGING_CWD"] == "/data/tenants/b/workspace"
      refute Map.has_key?(env, "HERMES_UID")
      refute Map.has_key?(env, "HERMES_GID")
    end
```
- Replace the `describe "data_mount_path/0 and file_browser_root/1"` block with:
```elixir
  describe "data_root/1 and file_browser_root/1" do
    test "both are the parent of instance.workspace" do
      inst = %{workspace: "/data/tenants/b/workspace"}
      assert Hermes.data_root(inst) == "/data/tenants/b"
      assert Hermes.file_browser_root(inst) == "/data/tenants/b"
    end

    test "handle missing workspace gracefully" do
      assert Hermes.data_root(%{}) == ""
      assert Hermes.file_browser_root(%{}) == ""
    end
  end
```
- Any test calling `Hermes.docker_image/0`, `gateway_command/0`, `parse_log_rejection/1`: delete it.

Run: `mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs 2>&1 | tail -3` — expect failures on the new tests.

- [ ] **Step 2: `Runtime` behaviour**

`apps/druzhok/lib/druzhok/runtime.ex`: delete the `docker_image`, `gateway_command`, `data_mount_path`, `parse_log_rejection` callbacks; add `@callback data_root(instance) :: String.t()`. Change `proxy_host/0`:
```elixir
  def proxy_host, do: System.get_env("LLM_PROXY_HOST") || "127.0.0.1"
```

- [ ] **Step 3: `Runtime.Hermes`**

- Delete `@data_mount`, `docker_image/0`, `gateway_command/0`, `data_mount_path/0`, `parse_log_rejection/1`.
- Add:
```elixir
  @impl true
  def data_root(instance) do
    case Map.get(instance, :workspace) do
      ws when is_binary(ws) and ws != "" -> Path.dirname(ws)
      _ -> ""
    end
  end

  @impl true
  def file_browser_root(instance), do: data_root(instance)
```
- In `env_vars/1`: `"HERMES_HOME" => data_root(instance)`, `"MESSAGING_CWD" => Path.join(data_root(instance), "workspace")`; delete the `HERMES_UID`/`HERMES_GID` entries and their comment; delete the `alias … BotManager` if unused.
- Update the moduledoc: replace the "One container per bot. `HERMES_HOME=/opt/data` points at…" sentence with "One systemd unit (or dev process) per bot. `HERMES_HOME` is the tenant's data root on disk (`/data/tenants/<name>` in prod)."

- [ ] **Step 4: `BotManager`**

Rewrite `apps/druzhok/lib/druzhok/bot_manager.ex` keeping `create/2`, `restart/1`, `delete/1`, `wipe_data_dir/1`, `safe_to_wipe?/1`, `data_root_base/0`, `write_workspace_files/2`, `sync_runtime_config/3` as they are, and replacing the rest:

```elixir
  def start(name) do
    case Repo.get_by(Instance, name: name) do
      nil ->
        {:error, :not_found}

      instance ->
        runtime = Druzhok.Runtime.get(instance.bot_runtime || "hermes")
        env = Druzhok.Runtime.base_env(instance) |> Map.merge(runtime.env_vars(instance))
        data_root = runtime.data_root(instance)

        File.mkdir_p!(Path.join(data_root, "home"))
        write_workspace_files(data_root, runtime.workspace_files(instance))
        sync_runtime_config(runtime, instance, data_root)

        case Druzhok.Host.start(name, env, data_root) do
          :ok ->
            Logger.info("Started bot #{name}")

            Task.start(fn ->
              case runtime.post_start(instance) do
                :ok -> :ok
                {:error, reason} -> Logger.error("Post-start for #{name} failed: #{inspect(reason)}")
              end
            end)

            Druzhok.HealthMonitor.register(name)
            Repo.update(Instance.changeset(instance, %{active: true}))
            {:ok, name}

          {:error, reason} ->
            Logger.error("Failed to start bot #{name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def stop(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance ->
        Druzhok.Host.stop(name)
        Druzhok.HealthMonitor.unregister(name)
        instance |> Ecto.Changeset.change(%{active: false}) |> Repo.update!()
    end
    :ok
  end

  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance ->
        Druzhok.Host.destroy(name)
        wipe_data_dir(instance)
        TokenPool.release(instance.id)
        Repo.delete(instance)
    end
    :ok
  end

  @doc "Unit/process state as a string: active | activating | inactive | failed | unknown"
  def status(name), do: name |> Druzhok.Host.status() |> Atom.to_string()

  @doc "Resource usage in the shape the dashboard renders, or nil."
  def stats(name) do
    case Druzhok.Host.stats(name) do
      %{mem_bytes: mem, cpu_usec: cpu} ->
        %{mem: human_bytes(mem), mem_bytes: mem, cpu: "#{Float.round(cpu / 1_000_000, 1)}s", net: ""}
      nil -> nil
    end
  end

  def exec(name, args) when is_list(args), do: Druzhok.Host.exec(name, args)

  def logs(name, lines \\ 200), do: Druzhok.Host.logs(name, lines)

  defp human_bytes(b) when b >= 1024 * 1024 * 1024, do: "#{Float.round(b / (1024 * 1024 * 1024), 2)}GiB"
  defp human_bytes(b) when b >= 1024 * 1024, do: "#{Float.round(b / (1024 * 1024), 1)}MiB"
  defp human_bytes(b) when b >= 1024, do: "#{div(b, 1024)}KiB"
  defp human_bytes(b), do: "#{b}B"
```
Delete: `status_for_container/1`, `stats_for_container/1`, `@mem_regex`, `@unit_factors`, `parse_mem_bytes/1`, `start_container/6`, `stop_container/1`, `host_uid/0`, `host_gid/0`, `cached_id/2`, `host_user_gid/0`, `container_name/1`, the `restart/1` `Process.sleep(1_000)` (systemd stop is synchronous; keep the lock). Update `create/2`: remove `sandbox: "docker"` from the merged config. Update the moduledoc: "Top-level API for bot lifecycle. Generates env/config, then delegates process control to `Druzhok.Host`."

`data_root_base/0`:
```elixir
  def data_root_base do
    (System.get_env("DRUZHOK_DATA_ROOT") || Application.get_env(:druzhok, :data_root_default))
    |> Path.expand()
  end
```
and in `create/2` use `data_root = data_root_base()`. Add to `config/config.exs`: `data_root_default: Path.expand("../../data/tenants", __DIR__)` and to `config/runtime.exs` under `if config_env() == :prod do`: `config :druzhok, data_root_default: "/data/tenants"`.

- [ ] **Step 5: `HealthMonitor` (status only for now; probe comes in Task 6)**

`apps/druzhok/lib/druzhok/health_monitor.ex`:
- `register(name)` (drop `container_id`, `bot_runtime` args; keep a 1-arity public API: `def register(name), do: GenServer.cast(__MODULE__, {:register, name})`).
- state entry: `%{failures: 0, status: :healthy}`.
- `do_health_check(name)`: `if Druzhok.Host.status(name) == :active, do: :ok, else: :error`.

`InstanceManager.create/2` and `save_to_db`: remove `sandbox:`. `Instance` schema: remove `field :sandbox` and from `cast`. `i18n.ex` sandbox strings were removed in Task 1.

Delete `log_watcher.ex`, `log_port.ex`, `log_port_test.exs`.

- [ ] **Step 6: Dashboard + settings tab**

`dashboard_live.ex` `list_instances/0`:
```elixir
    |> Task.async_stream(
      fn inst ->
        [status_task, stats_task] =
          Enum.map(
            [fn -> Druzhok.BotManager.status(inst.name) end,
             fn -> Druzhok.BotManager.stats(inst.name) end],
            &Task.async/1
          )
        …
```
Then grep the templates for the old Docker words:
```bash
grep -rn '"running"\|"exited"\|"not_found"\|"restarting"' apps/druzhok_web/lib | head
```
Replace `"running"` → `"active"`, `"exited"`/`"not_found"` → `"inactive"`/`"unknown"`, `"restarting"` → `"activating"` in every comparison and badge label.

`settings_tab.ex` `approve_pairing_code/2`:
```elixir
    {output, exit_code} =
      BotManager.exec(name, ["/opt/hermes/.venv/bin/hermes", "pairing", "approve", "telegram", code])
```
(remove the `user: "hermes"` option and the docker comment; in dev `Host.Process.exec` runs whatever `hermes` binary is configured — make the path `Application.get_env(:druzhok, :hermes_bin)`.)

- [ ] **Step 7: Compile, test, fix the ripple**

```bash
mix compile --force --warnings-as-errors 2>&1 | tail -20
mix test 2>&1 | tail -5
```
Expected: 0 failures. Typical ripples: `ManagerBot`/`Provisioner` referencing `BotManager.container_name` (replace with `BotManager.status`), `bot_manager_test.exs` still fine.

- [ ] **Step 8: Commit**

`/my-commit` — `BotManager delegates process control to Druzhok.Host; drop docker/log-watcher plumbing`.

---

### Task 6: Probe-based `HealthMonitor`

**Files:**
- Create: `apps/druzhok/lib/druzhok/health_monitor/probe.ex`, `apps/druzhok/test/druzhok/health_monitor/probe_test.exs`.
- Modify: `apps/druzhok/lib/druzhok/health_monitor.ex`, `apps/druzhok/lib/druzhok/telegram/api.ex` (confirm `get_me/1` exists — it does, used by ManagerBot).

**Interfaces:**
- Produces:
```elixir
Druzhok.HealthMonitor.Probe.run(instance, opts) :: {:healthy, []} | {:degraded, [reason]} | {:down, reason}
  # reasons are atoms-or-tuples: {:unit, status} | {:telegram, term} | {:llm, term} | :egress_open
  # opts: telegram_get_me: (token -> {:ok, _} | {:error, _}), llm_ping: (instance -> :ok | {:error, _}), egress_check: (name -> :closed | :open)
Druzhok.HealthMonitor.Probe.llm_ping(instance) :: :ok | {:error, term}   # POST http://127.0.0.1:PORT/v1/chat/completions with the tenant key
Druzhok.HealthMonitor.Probe.egress_check(name) :: :closed | :open        # Host.exec(name, ["curl","-m","3","-sS","http://127.0.0.1:22"]) ; exit 0 ⇒ :open
Druzhok.HealthMonitor.list() :: %{name => %{status: :healthy|:degraded|:down, reasons: [...], failures: n, checked_at: DateTime}}
```

- [ ] **Step 1: Failing tests**

`apps/druzhok/test/druzhok/health_monitor/probe_test.exs`:
```elixir
defmodule Druzhok.HealthMonitor.ProbeTest do
  use ExUnit.Case, async: true
  alias Druzhok.HealthMonitor.Probe

  @inst %{name: "b", telegram_token: "t", tenant_key: "k", model: "m"}

  defp opts(over) do
    Keyword.merge(
      [unit_status: fn _ -> :active end,
       telegram_get_me: fn _ -> {:ok, %{}} end,
       llm_ping: fn _ -> :ok end,
       egress_check: fn _ -> :closed end],
      over)
  end

  test "all green" do
    assert {:healthy, []} = Probe.run(@inst, opts([]))
  end

  test "unit not active is down and skips the rest" do
    parent = self()
    o = opts(unit_status: fn _ -> :failed end, telegram_get_me: fn _ -> send(parent, :called); {:ok, %{}} end)
    assert {:down, {:unit, :failed}} = Probe.run(@inst, o)
    refute_received :called
  end

  test "telegram + llm failures are degraded with both reasons" do
    o = opts(telegram_get_me: fn _ -> {:error, :unauthorized} end, llm_ping: fn _ -> {:error, 429} end)
    assert {:degraded, reasons} = Probe.run(@inst, o)
    assert {:telegram, :unauthorized} in reasons
    assert {:llm, 429} in reasons
  end

  test "open egress is degraded" do
    assert {:degraded, [:egress_open]} = Probe.run(@inst, opts(egress_check: fn _ -> :open end))
  end

  test "egress_check interprets exec exit code" do
    assert Probe.egress_check("b", exec: fn _, _ -> {"", 0} end) == :open
    assert Probe.egress_check("b", exec: fn _, _ -> {"refused", 7} end) == :closed
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test apps/druzhok/test/druzhok/health_monitor/probe_test.exs 2>&1 | tail -3`

- [ ] **Step 3: Implement `Probe`**

`apps/druzhok/lib/druzhok/health_monitor/probe.ex`:
```elixir
defmodule Druzhok.HealthMonitor.Probe do
  @moduledoc """
  One health probe for one bot: unit state, Telegram token, LLM path through
  the proxy, and egress lock-down. Pure given the injected functions, so it is
  unit-testable; defaults hit the real world.
  """
  require Logger

  @type reason :: {:unit, atom()} | {:telegram, term()} | {:llm, term()} | :egress_open
  @type result :: {:healthy, []} | {:degraded, [reason]} | {:down, reason}

  @spec run(map(), keyword()) :: result
  def run(instance, opts \\ []) do
    unit_status = Keyword.get(opts, :unit_status, &Druzhok.Host.status/1)
    get_me = Keyword.get(opts, :telegram_get_me, &Druzhok.Telegram.API.get_me/1)
    llm_ping = Keyword.get(opts, :llm_ping, &llm_ping/1)
    egress = Keyword.get(opts, :egress_check, &egress_check/1)

    case unit_status.(instance.name) do
      :active ->
        reasons =
          [
            case get_me.(instance.telegram_token) do
              {:ok, _} -> nil
              {:error, r} -> {:telegram, r}
            end,
            case llm_ping.(instance) do
              :ok -> nil
              {:error, r} -> {:llm, r}
            end,
            case egress.(instance.name) do
              :closed -> nil
              :open -> :egress_open
            end
          ]
          |> Enum.reject(&is_nil/1)

        if reasons == [], do: {:healthy, []}, else: {:degraded, reasons}

      other ->
        {:down, {:unit, other}}
    end
  end

  @doc "One 1-token completion through the proxy with the bot's tenant key."
  def llm_ping(instance) do
    port = System.get_env("LLM_PROXY_PORT") || "4000"
    url = "http://127.0.0.1:#{port}/v1/chat/completions"
    body = Jason.encode!(%{model: instance.model, max_tokens: 1, messages: [%{role: "user", content: "ping"}]})
    headers = [{"authorization", "Bearer #{instance.tenant_key}"}, {"content-type", "application/json"}]

    case Finch.build(:post, url, headers, body) |> Finch.request(Druzhok.LocalFinch, receive_timeout: 15_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, s}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  @doc "Must NOT be able to reach a non-proxy local port from inside the bot."
  def egress_check(name, opts \\ []) do
    exec = Keyword.get(opts, :exec, &Druzhok.Host.exec/2)
    case exec.(name, ["curl", "-m", "3", "-sS", "-o", "/dev/null", "http://127.0.0.1:22"]) do
      {_, 0} -> :open
      _ -> :closed
    end
  end
end
```

- [ ] **Step 4: Rewrite `HealthMonitor` around the probe**

`apps/druzhok/lib/druzhok/health_monitor.ex`:
```elixir
defmodule Druzhok.HealthMonitor do
  @moduledoc """
  Runs `Druzhok.HealthMonitor.Probe` for every registered bot every 60 s.
  Three consecutive `:down` results restart the bot. Every transition into
  degraded/down is recorded in `crash_logs` so /errors is the alert feed.
  """
  use GenServer
  require Logger

  @interval 60_000
  @max_failures 3
  @probe_timeout 20_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def register(name), do: GenServer.cast(__MODULE__, {:register, name})
  def unregister(name), do: GenServer.cast(__MODULE__, {:unregister, name})
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_), do: (schedule(); {:ok, %{bots: %{}}})

  @impl true
  def handle_cast({:register, name}, s) do
    {:noreply, put_in(s, [:bots, name], %{status: :healthy, reasons: [], failures: 0, checked_at: nil})}
  end
  def handle_cast({:unregister, name}, s), do: {:noreply, %{s | bots: Map.delete(s.bots, name)}}

  @impl true
  def handle_call(:list, _from, s), do: {:reply, s.bots, s}

  @impl true
  def handle_info(:check, s) do
    instances = Druzhok.InstanceManager.list() |> Map.new(&{&1.name, &1})

    results =
      s.bots
      |> Map.keys()
      |> Task.async_stream(fn name ->
        case instances[name] do
          nil -> {name, {:down, {:unit, :unknown}}}
          inst ->
            {name, Druzhok.HealthMonitor.Probe.run(inst)}
        end
      end, timeout: @probe_timeout, on_timeout: :kill_task, max_concurrency: 4)
      |> Enum.map(fn
        {:ok, {name, res}} -> {name, res}
        {:exit, _} -> nil
      end)
      |> Enum.reject(&is_nil/1)

    bots = Enum.reduce(results, s.bots, fn {name, res}, acc -> Map.update!(acc, name, &apply_result(name, &1, res)) end)
    schedule()
    {:noreply, %{s | bots: bots}}
  end

  defp apply_result(name, info, {:healthy, []}) do
    if info.status != :healthy, do: Logger.info("Bot #{name} healthy again")
    %{info | status: :healthy, reasons: [], failures: 0, checked_at: DateTime.utc_now()}
  end

  defp apply_result(name, info, {:degraded, reasons}) do
    if info.status != :degraded or info.reasons != reasons, do: log(name, "degraded", reasons)
    %{info | status: :degraded, reasons: reasons, failures: 0, checked_at: DateTime.utc_now()}
  end

  defp apply_result(name, info, {:down, reason}) do
    failures = info.failures + 1
    if info.status != :down, do: log(name, "down", [reason])
    Logger.warning("Bot #{name} down (#{failures}/#{@max_failures}): #{inspect(reason)}")

    if failures >= @max_failures do
      Druzhok.Events.broadcast(name, %{type: :health_restart})
      Task.start(fn -> Druzhok.BotManager.restart(name) end)
      %{info | status: :down, reasons: [reason], failures: 0, checked_at: DateTime.utc_now()}
    else
      %{info | status: :down, reasons: [reason], failures: failures, checked_at: DateTime.utc_now()}
    end
  end

  defp log(name, level_word, reasons) do
    Druzhok.CrashLog.insert(%{
      level: if(level_word == "down", do: "error", else: "warning"),
      message: "Bot #{name} #{level_word}: #{inspect(reasons)}",
      source: "Druzhok.HealthMonitor",
      instance_name: name
    })
  end

  defp schedule, do: Process.send_after(self(), :check, @interval)
end
```
Check `Druzhok.CrashLog.insert/1` signature (`grep -n "def insert" apps/druzhok/lib/druzhok/crash_log.ex`) and adapt the map keys if different.

- [ ] **Step 5: Expose in the dashboard sidebar**

In `dashboard_live.ex`, where `list_instances/0` builds the map, add `|> Map.put(:health, Map.get(Druzhok.HealthMonitor.list(), inst.name))` (fetch `HealthMonitor.list()` once before the `Task.async_stream`). In the sidebar template that renders the status badge, add after it:
```heex
<%= if h = inst[:health] do %>
  <span class={"text-[10px] uppercase " <> case h.status do :healthy -> "text-ok"; :degraded -> "text-warn"; _ -> "text-err" end}
        title={inspect(h.reasons)}><%= h.status %></span>
<% end %>
```
(Use the colour classes that already exist in `app.css` — `grep -n "text-ok\|text-warn\|text-err" apps/druzhok_web/assets/css/app.css`; fall back to `text-muted` if absent.)

- [ ] **Step 6: Run suite, commit**

```bash
mix test 2>&1 | tail -5
```
`/my-commit` — `HealthMonitor: real probe (unit, telegram, llm via proxy, egress)`.

---

### Task 7: Proxy hardening — tenant key on every route, admin gating

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/router.ex:31-43,54-66`, `apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex` (`audio_transcriptions` :252, `audio_speech` :399, `firecrawl_search` :497, `responses_proxy` :792, `resolve_instance` :1003), `apps/druzhok_web/lib/druzhok_web_web/live/{usage_live,errors_live,processes_live}.ex`.
- Create: `apps/druzhok_web/test/druzhok_web_web/router_auth_test.exs`.

**Interfaces:**
- Consumes: `DruzhokWebWeb.Plugs.LlmAuth` assigns `conn.assigns.instance`.
- Produces: all `/v1/*` and `/v2/*` routes 401 without a valid Bearer tenant key; `/usage`, `/errors`, `/processes` redirect non-admins to `/`.

- [ ] **Step 1: Failing tests**

`apps/druzhok_web/test/druzhok_web_web/router_auth_test.exs`:
```elixir
defmodule DruzhokWebWeb.RouterAuthTest do
  use DruzhokWebWeb.ConnCase, async: false

  @routes [
    "/v1/chat/completions", "/v1/embeddings", "/v1/images/generations",
    "/v1/audio/transcriptions", "/v1/audio/speech", "/v1/responses", "/v2/search"
  ]

  for route <- @routes do
    test "POST #{route} without key is 401", %{conn: conn} do
      conn = post(conn, unquote(route), %{})
      assert conn.status == 401
      assert %{"error" => %{"type" => "authentication_error"}} = Jason.decode!(conn.resp_body)
    end

    test "POST #{route} with bogus key is 401", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer nope") |> post(unquote(route), %{})
      assert conn.status == 401
    end
  end

  for path <- ["/usage", "/errors", "/processes"] do
    test "GET #{path} as non-admin redirects to /", %{conn: conn} do
      {:ok, user} =
        %Druzhok.User{} |> Druzhok.User.changeset(%{email: "u#{System.unique_integer([:positive])}@x", password: "secret123", role: "user"}) |> Druzhok.Repo.insert()
      conn = conn |> init_test_session(%{user_id: user.id}) |> get(unquote(path))
      assert redirected_to(conn) == "/"
    end
  end
end
```
Check `Druzhok.User.changeset/2` field names (`grep -n "cast\|field" apps/druzhok/lib/druzhok/user.ex`) and adjust the insert. If the LiveViews already redirect admins-only in `mount`, the test still must pass via the router plug (belt and braces).

- [ ] **Step 2: Run, expect failures on the unpipelined routes**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/router_auth_test.exs 2>&1 | tail -5`

- [ ] **Step 3: Router**

Replace lines 23-43 of `router.ex` with:
```elixir
  scope "/v1", DruzhokWebWeb do
    pipe_through :llm_api

    post "/chat/completions", LlmProxyController, :chat_completions
    post "/embeddings", LlmProxyController, :embeddings
    post "/images/generations", LlmProxyController, :images_generations
    post "/audio/transcriptions", LlmProxyController, :audio_transcriptions
    post "/audio/speech", LlmProxyController, :audio_speech
    post "/responses", LlmProxyController, :responses_proxy
  end

  # Firecrawl-compatible v2 API (only /search — hermes web_search via FIRECRAWL_API_URL).
  scope "/v2", DruzhokWebWeb do
    pipe_through :llm_api
    post "/search", LlmProxyController, :firecrawl_search
  end
```
and the protected scope:
```elixir
  pipeline :admin do
    plug :require_admin
  end

  scope "/", DruzhokWebWeb do
    pipe_through [:browser, :auth]
    live "/", DashboardLive
    live "/instances/:name", DashboardLive
    live "/instances/:name/:tab", DashboardLive
  end

  scope "/", DruzhokWebWeb do
    pipe_through [:browser, :auth, :admin]
    live "/settings", SettingsLive
    live "/models", ModelsLive
    live "/errors", ErrorsLive
    live "/usage", UsageLive
    live "/processes", ProcessesLive
  end
```
with `import DruzhokWebWeb.Auth, only: [require_admin: 2]` near the top of the router module.

Note: `:llm_api` has `plug :accepts, ["json"]` — `audio_transcriptions` receives multipart. Remove `:accepts` from the pipeline (it only checks the `Accept` header, but hermes may send `*/*`; keep it safe):
```elixir
  pipeline :llm_api do
    plug DruzhokWebWeb.Plugs.LlmAuth
  end
```

- [ ] **Step 4: Controller**

In `llm_proxy_controller.ex`: in `audio_transcriptions`, `audio_speech`, `firecrawl_search`, `responses_proxy` replace `instance = resolve_instance(conn)` with `instance = conn.assigns.instance` and delete the `if instance do … else do_…(conn, or_key, nil) end` branches so the budget check always runs. Delete `resolve_instance/1`. Then:
```bash
grep -n "nil" apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex | grep -i "instance" | head
```
and remove any remaining `instance == nil` / `if instance` guards in the helpers those four actions call (`do_audio_transcription/3`, speech, search, responses) — `instance` is now always a struct.

- [ ] **Step 5: Run full suite, commit**

```bash
mix test 2>&1 | tail -5
```
`/my-commit` — `require tenant key on every proxy route; admin-gate usage/errors/processes`.

---

### Task 8: Docs — `CLAUDE.md`, README, `update-hermes` skill

**Files:**
- Modify: `CLAUDE.md` (repo root), `v4/druzhok/README.md`, `~/.claude/skills/update-hermes/SKILL.md`.

- [ ] **Step 1: Rewrite `CLAUDE.md`**

Replace the whole file with:
````markdown
# Druzhok

Multi-tenant Hermes bot hosting. Elixir/Phoenix orchestrator (`v4/druzhok`) runs
one **systemd unit + Linux user per bot** on the KZ server; all LLM traffic goes
through Druzhok's OpenAI-compatible proxy (budgets, metering). No Docker.

## Commits

Always use `/my-commit` for committing changes.

## Critical Rules

- **Never wipe a bot's data dir** (`/data/tenants/<name>`) — it holds memory/identity. Only `BotManager.delete/1` may, and only on explicit user request.
- **Never set HTTP_PROXY/HTTPS_PROXY for bots** — breaks multipart uploads.
- **One Telegram poller per token.** Stop a bot on the old host before starting it elsewhere.
- Hermes source is the fork `github.com/iforaa/druzhok-hermes` (local clone `v4/hermes-agent`, upstream remote `upstream`). Updates go through the `update-hermes` skill.

## Layout

```
v4/druzhok/apps/druzhok/      core: BotManager, Host (Systemd|Process), Runtime.Hermes, HealthMonitor, ManagerBot, Budget
v4/druzhok/apps/druzhok_web/  Phoenix dashboard + LLM proxy (LlmProxyController) + BotSite plug
v4/druzhok/ops/               druzhok-ctl, hermes@.service, nftables, Caddyfile, bootstrap.sh, smoke.sh
workspace-template/           Hermes workspace seed (AGENTS.md, SOUL.md, …)
docs/superpowers/specs|plans  design docs
```

## Proxy endpoints (all require `Authorization: Bearer <tenant_key>`)

| Endpoint | Upstream |
|---|---|
| `POST /v1/chat/completions`, `/v1/embeddings`, `/v1/images/generations`, `/v1/responses` | OpenRouter |
| `POST /v1/audio/transcriptions` | OpenRouter (Gemini Flash `input_audio`) |
| `POST /v1/audio/speech` | OpenAI TTS |
| `POST /v2/search` | OpenRouter perplexity/sonar (Firecrawl-compatible shape) |

OpenRouter responses have leading whitespace — `String.trim()` before `Jason.decode()`.

## Development (macOS, no Docker)

```bash
cd v4/druzhok
mix deps.get && mix compile && mix test
# a local hermes venv for Host.Process:
HERMES_BIN=/path/to/druzhok-hermes/.venv/bin/hermes DATABASE_PATH=data/druzhok.db mix phx.server
```

## Server (KZ, PS Cloud Almaty)

```bash
ssh ubuntu@195.49.213.8
cd ~/druzhok && git pull
cd v4/druzhok && . ~/.asdf/asdf.sh && mix compile
DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix ecto.migrate
sudo systemctl restart druzhok
```

Bots: `sudo druzhok-ctl status|logs|restart <name>`; `journalctl -u hermes@<name> -f`.
Hermes install: `/opt/hermes` (`git pull && uv sync --extra all --extra messaging --extra firecrawl`, then restart bots one at a time — operator's bot first, `ops/smoke.sh`).

## Debugging

```bash
journalctl -u druzhok --since '5 min ago' | grep -i error | tail -20
sudo druzhok-ctl logs <name> 100
sudo nft list table inet druzhok      # per-bot egress counters
curl -s -H "Authorization: Bearer <tenant_key>" http://127.0.0.1:4000/v1/chat/completions -d '{"model":"x","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
```
````

- [ ] **Step 2: README**

`v4/druzhok/README.md` — replace `# V3 … TODO` with a 10-line pointer: what it is, `mix test`, `mix phx.server` with `HERMES_BIN`, link to `CLAUDE.md` and the spec.

- [ ] **Step 3: `update-hermes` skill**

Rewrite `~/.claude/skills/update-hermes/SKILL.md` keeping Step 0b (snapshot → fetch `upstream` → reset to a **release tag**, not main tip), the changelog block, Customization 1 (authz DM-pair guard, unchanged), and replacing everything from "Customization 4" onward with:
```markdown
### Customization 4: firecrawl — REMOVED (native extra since v2026.7)
`pyproject.toml` has `firecrawl = ["firecrawl-py==4.17.0"]`; install with `--extra firecrawl`. No Dockerfile patch.

## Step 2: Push the fork
git push -f origin main   # origin = github.com/iforaa/druzhok-hermes ; upstream = nousresearch
git push origin druzhok-patches-<date>

## Step 3: Update the server
ssh ubuntu@195.49.213.8 'cd /opt/hermes && sudo git fetch origin && sudo git reset --hard origin/main && sudo uv sync --extra all --extra messaging --extra firecrawl'

## Step 4: Roll bots one at a time
ssh ubuntu@195.49.213.8 'sudo druzhok-ctl restart <operator-bot> && sleep 30 && sudo druzhok-ctl status <operator-bot>'
ssh ubuntu@195.49.213.8 'cd ~/druzhok/v4/druzhok && ops/smoke.sh <operator-bot>'
# then the rest: for b in …; do sudo druzhok-ctl restart $b; sleep 30; done

## Step 5: Verify
ssh ubuntu@195.49.213.8 'for u in $(systemctl list-units "hermes@*" --no-legend | awk "{print \$1}"); do echo "$u $(systemctl is-active $u)"; done'
```
Delete the Docker build/stream/disk-space steps, the Yandex IP/WireGuard notes, and the entire "Upgrading honcho" section.

- [ ] **Step 4: Commit**

`/my-commit` — `docs: CLAUDE.md/README for systemd hosting; update-hermes skill without docker`. (The skill file is outside the repo — no commit needed for it; mention it in the commit body.)

---

## Self-Review

**Spec coverage**
- Server layout, unit, ctl, nftables, Caddy, bootstrap, smoke, export/import, rollout → companion ops plan (explicitly out of this plan).
- `Druzhok.Host` behaviour + Systemd + Process → Tasks 3–4. ✔
- `BotManager` delegation, `Runtime` callback changes, `data_root/1`, `proxy_host` default, `HERMES_UID` removal → Task 5. ✔
- `HealthMonitor` probe incl. egress self-test and `CrashLog` rows → Task 6. ✔
- Deletions list (sandbox, Instance.Sup, Scheduler, InstanceWatcher, LogWatcher/LogPort, HonchoJwt, ChatChannel/Socket, sandbox-agent, docker-entrypoint, stale workspace-template, translations.json, InstanceDynSup, other runtimes, sandbox i18n) → Tasks 1, 2, 5. ✔ `config/Caddyfile` removal belongs with `ops/Caddyfile` in the ops plan.
- Honcho removal incl. migration → Task 2. ✔
- Proxy: tenant key on every route, `require_admin` on the three LiveViews → Task 7. ✔
- Tests: Host.Systemd fake ctl, Host.Process stub, probe, router 401s, stale tests fixed → Tasks 1, 3, 4, 6, 7. ✔
- Docs / skill → Task 8. ✔

**Type consistency**
- `Host.status/1` returns atoms; `BotManager.status/1` returns the string form; dashboard compares strings (`"active"`). Task 5 Step 6 updates the templates.
- `HealthMonitor.register/1` is 1-arity everywhere (BotManager Task 5, module Task 6).
- `Probe.run/2` result shape `{:healthy, []} | {:degraded, [reason]} | {:down, reason}` matches `apply_result/3` clauses.
- `Host.Systemd.env_file/1` test expectation: input `%{"B" => ~s(say "hi" \\ $X)}` is the Elixir string `say "hi" \ $X`; serialised as `B="say \"hi\" \\ $X"` — the test literal `~s(A="1"\nB="say \\"hi\\" \\\\ $X"\n)` encodes exactly that. ✔

**Placeholders** — none; every step has concrete code or commands.
