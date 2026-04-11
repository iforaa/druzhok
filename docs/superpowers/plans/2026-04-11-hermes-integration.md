# Hermes integration + pool decommission

**Date:** 2026-04-11
**Scope:** Add `hermes` as a supported `bot_runtime` in druzhok v4, run one container per bot, drop the pool architecture, keep dashboard working for all four runtimes (`hermes`, `openclaw`, `zeroclaw`, `picoclaw`, `nullclaw`).

---

## Current state snapshot

- Druzhok elixir runs as `systemd: druzhok.service` directly on host (no container), `mix phx.server`, `MIX_ENV=dev`, listens `0.0.0.0:4000`. Nginx at `:80` reverse-proxies to it. Secrets live in the systemd unit file.
- Data root on host: `/home/igor/druzhok-data/v4-instances/{tenant_name}/workspace/`, owned by `igor:igor`.
- One `druzhok-pool-1` container running `openclaw:latest` with `--network host`, mounts `/var/run/docker.sock` + per-tenant workspaces at their host paths + `/home/igor/druzhok-data/v4-instances/pools/openclaw-pool-1 → /data`.
- Sandbox containers (`openclaw-sbx-agent-*`) are *siblings* of the pool, not nested. They run on the host's docker daemon via the mounted socket. Network `bridge`, not privileged, mount only the specific tenant workspace at `/workspace`.
- Existing tenants: `Igz`, `igor`, `openigor`, `vasa`, `zhora`. Five bots total. Workspace sizes ~1–3MB each.
- No `hermes` image exists on the remote.
- `openclaw:latest` = 2.95GB. Hermes will be comparable.

## Target state

```
host
├── druzhok.service (unchanged)
├── docker: druzhok-bot-Igz     (hermes:latest, --network host, -v Igz/workspace:/opt/data, --user 1000:1000)
├── docker: druzhok-bot-igor    (openclaw:latest, --network host, -v igor/workspace:/opt/data)
├── docker: druzhok-bot-vasa    (zeroclaw:latest, ...)
└── docker: druzhok-bot-zhora   (hermes:latest, ...)
```

- No pool container. No shared V8 process. Each bot gets its own container.
- OpenClaw bots run the single-instance `openclaw.json` config that `OpenClaw.workspace_files/1` already knows how to build.
- Hermes bots are configured entirely via environment variables plus an optional seed `config.yaml` written only on first boot.
- Bot containers run as the host user's UID so files on the host stay `igor:igor`.

---

## Phases

### Phase 0 — Decisions to lock before coding

The following need a yes/no before starting. Defaults in **bold**.

1. **Run hermes as `igor` UID (1000:1000) via `--user` flag.** Alternative: run as root and `chown` after, which is uglier. The only risk is a runtime operation inside hermes needing `root`; I don't believe there is one (pip/apt/playwright download all happened at build time).
2. **Do not mount `/var/run/docker.sock` into hermes.** Alternative: mount it to let hermes spawn docker sandboxes for tool execution. We don't need it — hermes already runs its terminal/browser/code tools in-process inside its own container.
3. **`--network host` for hermes, same as today.** Alternative: bridge network with `--add-host=host.docker.internal:host-gateway`. Host net is simpler and matches the existing pattern; bridge is more isolated but needs the `host.docker.internal` plumbing. Host net is fine because druzhok listens on `0.0.0.0:4000` anyway.
4. **Kill pooling completely, don't feature-flag it.** Alternative: keep pool code gated behind a `USE_POOL=true` env var for rollback. We already verified openclaw's non-pool `workspace_files/1` + `post_start/1` are complete and unreachable-but-correct. Flipping them on is the refactor. Keeping both paths is dead weight.
5. **Deploy hermes image via `save | gzip | rsync | load`**, same recipe as openclaw in `CLAUDE.md`. Alternative: push to a registry. We have no registry configured; local transfer is fine for one image.
6. **Build hermes image from `v4/hermes-agent/` unchanged.** Alternative: add a `docker/entrypoint-druzhok.sh` to bootstrap differently. The upstream `docker/entrypoint.sh` already does what we need (seeds defaults from templates if missing). No fork needed.

> **Action:** user confirms these before Phase 1 starts.

### Phase 1 — Build and ship the hermes image

1. On the laptop (darwin/arm64), cross-build for linux/amd64:
   ```bash
   cd /Users/igorkuznetsov/Documents/druzhok/v4/hermes-agent
   docker buildx build --platform linux/amd64 -t hermes:latest --load .
   ```
   Expected size: ~3GB (Debian + Python + Node + Playwright Chromium + ffmpeg + ripgrep).

2. Save, compress, transfer, load:
   ```bash
   docker save hermes:latest | gzip > /tmp/hermes.tar.gz
   rsync --partial --progress -e ssh /tmp/hermes.tar.gz igor@158.160.78.230:/tmp/
   ssh igor@158.160.78.230 "gunzip -c /tmp/hermes.tar.gz | docker load && rm /tmp/hermes.tar.gz"
   ```

3. Verify on remote:
   ```bash
   ssh igor@158.160.78.230 "docker images | grep hermes"
   ```

4. Smoke-test the image manually before wiring anything:
   ```bash
   ssh igor@158.160.78.230 "mkdir -p /tmp/hermes-smoke && \
     docker run --rm -it \
       --user 1000:1000 \
       -e HERMES_HOME=/opt/data \
       -e TELEGRAM_BOT_TOKEN=<test-token> \
       -e TELEGRAM_ALLOWED_USERS=<your-id> \
       -e OPENAI_BASE_URL=http://127.0.0.1:4000/v1 \
       -e OPENAI_API_KEY=<test-tenant-key> \
       -e HERMES_INFERENCE_PROVIDER=custom \
       -v /tmp/hermes-smoke:/opt/data \
       --network host \
       hermes:latest gateway"
   ```
   Watch for: does it start, does it detect the telegram token, does it reach the LLM proxy, does `/opt/data` get populated with `cron/`, `sessions/`, `logs/`, etc., and are those files owned by `igor:igor` on the host?

   **Stop if this doesn't work.** Everything downstream depends on it.

### Phase 2 — Hermes runtime adapter

**File:** `apps/druzhok/lib/druzhok/runtime/hermes.ex` (new)

Implements the `Druzhok.Runtime` behaviour. Sketch (refine during implementation):

```elixir
defmodule Druzhok.Runtime.Hermes do
  @behaviour Druzhok.Runtime

  @impl true
  def pooled?, do: false

  @impl true
  def docker_image, do: System.get_env("HERMES_IMAGE") || "hermes:latest"

  @impl true
  def gateway_command, do: ["gateway"]

  @impl true
  def env_vars(instance) do
    proxy = "http://#{Druzhok.Runtime.proxy_host()}:4000/v1"
    %{
      "HERMES_HOME" => "/opt/data",
      "HERMES_QUIET" => "0",
      "TELEGRAM_BOT_TOKEN" => instance.telegram_token || "",
      "TELEGRAM_ALLOWED_USERS" => build_allowlist(instance),
      "HERMES_INFERENCE_PROVIDER" => "custom",
      "OPENAI_BASE_URL" => proxy,
      "OPENAI_API_KEY" => instance.tenant_key || "",
      "HERMES_MODEL" => instance.model || "anthropic/claude-opus-4.6"
    }
  end

  @impl true
  def workspace_files(instance), do: seed_files(instance)
  # Writes /opt/data/config.yaml ONLY if it doesn't already exist on first run.
  # Writes SOUL.md from a druzhok-owned template (NOT the hermes upstream one).

  @impl true
  def post_start(_instance), do: :ok

  @impl true
  def read_allowed_users(data_root) do
    path = Path.join(data_root, "platforms/pairing/telegram-approved.json")
    with {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      Map.keys(map)
    else
      _ -> []
    end
  end

  # Both are env-var driven: mutating instance.allowed_telegram_ids + restart
  # rebuilds TELEGRAM_ALLOWED_USERS. Hermes's pairing store (file-based) is
  # left to hermes to manage.
  @impl true
  def add_allowed_user(_data_root, _user_id), do: :ok
  @impl true
  def remove_allowed_user(_data_root, _user_id), do: :ok

  @impl true
  def clear_sessions(data_root) do
    Path.join(data_root, "sessions") |> File.rm_rf!()
    :ok
  end

  @impl true
  def parse_log_rejection(_line), do: :ignore
  # Hermes has its own pairing flow (gateway/pairing.py). Druzhok does not
  # need to intercept. If we later want dashboard-mediated approval, hook
  # into hermes's pairing store directly instead of log parsing.

  @impl true
  def supports_feature?(:pairing), do: false
  def supports_feature?(_), do: false

  defp build_allowlist(instance) do
    [instance.owner_telegram_id | Druzhok.Instance.get_allowed_ids(instance)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp seed_files(_instance) do
    # Start minimal. Only write files whose defaults we need to override.
    # Most config comes via env vars; config.yaml is untouched on restart so
    # hermes can persist runtime state (thread IDs etc) there without clobber.
    []
  end
end
```

**Register it:** `runtime.ex:24-29` → add `"hermes" => Druzhok.Runtime.Hermes`.

**Note on `workspace_files/1` and templates:** You wrote "make sure the template is copy pasting correct hermes files, not the openclaw ones." Today, ZeroClaw and OpenClaw each write their own config files via `workspace_files/1`, and the call site in `bot_manager.ex:83-87` writes them relative to `data_root`. Because each runtime module owns its own template, the paths never collide — but we should audit if anything is written in a runtime-generic location. Current check:
- `ZeroClaw.workspace_files/1` writes `.zeroclaw/config.toml` + `workspace/TOOLS.md`.
- `OpenClaw.workspace_files/1` writes `openclaw.json` + optionally `workspace/TOOLS.md`.
- Both write `workspace/TOOLS.md`! If you change runtime on an existing tenant, the old `TOOLS.md` survives. Not a hermes problem, but worth a note: `Hermes.workspace_files/1` should *not* write anything to `workspace/` (hermes uses `/opt/data` as its root, which is `data_root`, and the `workspace/` subdir is hermes-internal). Our seed (if any) goes to `data_root/config.yaml` or `data_root/.env`, not under `workspace/`.

**What about an initial SOUL.md / config.yaml?** The hermes upstream entrypoint already creates defaults on fresh volumes (it copies `/opt/hermes/cli-config.yaml.example` → `/opt/data/config.yaml` and `/opt/hermes/docker/SOUL.md` → `/opt/data/SOUL.md` if missing). For druzhok-customised defaults, we have two options:
- **Option A (recommended for v1):** do nothing — let hermes bootstrap its own defaults. `env_vars/1` carries everything druzhok needs to inject per-tenant (token, allowlist, proxy URL, model, tenant_key).
- **Option B:** ship druzhok-owned templates at `v4/druzhok/priv/runtime_templates/hermes/` (config.yaml.eex + SOUL.md.eex) and have `workspace_files/1` render them on first boot. Pick this later if v1 leaves you wanting tenant-specific defaults.

### Phase 3 — BotManager + HealthMonitor cleanup

1. **`BotManager.start/1`** (`bot_manager.ex:45-124`): remove the `if runtime.pooled?()` branch (lines 51-75). All runtimes now take the standalone path.

2. **`BotManager.stop/1`**: remove the pooled branch (lines 135-137).

3. **`BotManager.restart/1`**: remove the pooled branch (lines 152-154).

4. **Add `--user` flag + browser-tool requirements to `start_container/5`** (`bot_manager.ex:200-214`):
   ```elixir
   defp start_container(name, image, env, workspace, command) do
     env_args = Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
     user_id = "#{System.cmd("id", ["-u"]) |> elem(0) |> String.trim()}:" <>
               "#{System.cmd("id", ["-g"]) |> elem(0) |> String.trim()}"

     args = ["run", "-d",
       "--name", container_name(name),
       "--network", "host",
       "--restart", "unless-stopped",
       "--user", user_id,            # NEW: files stay host-owned
       "--shm-size", "2g",            # NEW: Chromium needs /dev/shm space
       "-v", "#{workspace}:/data"     # note: /data is the mount for zero/pico/openclaw.
     ] ++ env_args ++ [image | List.wrap(command)]

     ...
   end
   ```
   **Wait — the mount point differs between runtimes.** Hermes uses `/opt/data`, others use `/data`. The mount target should come from the runtime adapter, not be hardcoded. Add a behaviour callback `data_mount_path/0` that returns `/data` (default) or `/opt/data` (hermes).

5. **HealthMonitor** (`health_monitor.ex:82-87`): already uses `docker inspect {{.State.Running}}` which works for every runtime. No changes needed. The dead `health_path/0` + `health_port/0` behaviour callbacks can be removed from `runtime.ex:13-14` while we're in there (none of them are called anywhere after pool decommission).

6. **Pool decommission** — separate commit, not mixed with hermes:
   - `OpenClaw.pooled?/0` → `false` (this activates the already-complete single-instance code path in `open_claw.ex:16-51, 131-195`).
   - Delete `apps/druzhok/lib/druzhok/pool_manager.ex`, `pool_observer.ex`, `pool_config.ex`, `pool.ex` (schema), plus migration that created the `pools` table. **Do not delete `log_port.ex`** — it's still used by `log_watcher.ex`.
   - Delete `apps/druzhok/test/druzhok/pool_manager_test.exs`, `pool_config_test.exs`.
   - Remove `pool_id` column from `instances` (migration). Set all existing `pool_id` values to `nil` in the same migration.
   - Remove all references to `Druzhok.PoolManager`, `Druzhok.Pool`, `Druzhok.PoolConfig`, `Druzhok.PoolObserver` from the codebase (grep + remove).
   - On the remote: `docker rm -f druzhok-pool-1`, `docker rm -f openclaw-sbx-agent-igz-*` after restart, then restart the existing Igz bot as a new standalone OpenClaw container.

### Phase 4 — Dashboard compatibility audit

This is the part where silent bugs hide. Every place the dashboard makes a decision based on `bot_runtime`, pool state, or per-runtime file layout, we either update it or accept graceful degradation for hermes.

**Audit checklist — each of these needs to be verified for all five runtimes (`hermes`, `openclaw`, `zeroclaw`, `picoclaw`, `nullclaw`):**

1. **Create bot dropdown** — `DashboardLive.render` around line 463: `<option :for={name <- Druzhok.Runtime.names()} value={name}>`. Already iterates `Runtime.names()`. If we register `"hermes"` in `runtime.ex:@runtimes`, it shows up automatically. **Verify:** create a hermes bot from the UI, check it saves with `bot_runtime: "hermes"`.

2. **Sidebar bot list** — `dashboard_live.ex:479-487` shows `inst[:bot_runtime] || "zeroclaw"` next to each instance. Works as-is. Runtime badge colors at `dashboard_live.ex:458-461` (inside `runtime_badge_color/1`) only handle 4 runtimes — **add `"hermes"` to the color map**, pick a distinctive color.

3. **Pool sidebar section** — `dashboard_live.ex:490-503`. After Phase 3 pool decommission, `@pools` will always be empty. Either remove the block entirely or guard it off. **Cleanup task, part of Phase 3.**

4. **Settings tab** — `SettingsTab` LiveComponent (the recent refactor).
   - Telegram token save/restart → works for all runtimes (env var at container start).
   - Allowed users (TELEGRAM_ALLOWED_USERS env) → works for hermes (add/remove updates `instance.allowed_telegram_ids` in the DB then restart). Different from zeroclaw which writes TOML. Both honoured by the adapter contract — `add_allowed_user/2` is a no-op for hermes, `build_allowlist/1` reads from DB at every start.
   - Model switcher → hermes reads from `HERMES_MODEL` env; restart picks up new model. Works.
   - Dreaming → this is openclaw-specific (memory-core plugin). Hermes doesn't have it. **Need:** hide the Dreaming section unless `runtime.supports_feature?(:dreaming)` is true. Add the feature flag to the behaviour, return `true` for OpenClaw only.
   - Heartbeat → this is OpenClaw-specific too (built into pool_config.ex's heartbeat block). Hermes doesn't have a concept of heartbeat. **Need:** hide the Heartbeat section unless `supports_feature?(:heartbeat)` is true.
   - Fallback models → OpenClaw-specific. Same deal — feature flag.
   - Clear history → for hermes, `clear_sessions/1` rm-rfs `/opt/data/sessions`. Works.
   - Trigger name / mention-only → OpenClaw group chat config. Hermes has its own group chat config shape. v1 hides these for hermes, add later.

   **Action:** Add `Runtime.supports_feature?/1` values for `:dreaming`, `:heartbeat`, `:fallback_models`, `:group_chat_config`. Gate the settings sections on these. Hermes returns `false` for all of them in v1.

5. **Files tab** — `FilesTab` LiveComponent browses `instance[:workspace]`. For all runtimes, `instance.workspace` in the DB points to `/home/igor/druzhok-data/v4-instances/{name}/workspace/`. For hermes, the container mount is `/opt/data` pointing at the parent dir (`/home/igor/druzhok-data/v4-instances/{name}/`). The dashboard file browser will show the `workspace/` subdir, but hermes's other dirs (`cron/`, `sessions/`, `logs/`, `memories/`, `skills/`, `SOUL.md`, `config.yaml`) will be *above* that in the parent dir.

   **Decision needed:** for hermes, do we want the Files tab to browse `workspace/` only (like other runtimes, symmetric) or the whole `/opt/data` (so you can see SOUL.md, sessions, etc.)?

   **Recommendation:** introduce `Runtime.file_browser_root(instance)` callback that returns the path the Files tab should root at. Default implementation returns `instance.workspace` (what it does today). Hermes overrides to return `Path.dirname(instance.workspace)` (the `/opt/data` equivalent — `/home/igor/druzhok-data/v4-instances/{name}/`). This preserves the existing tenants' UX and gives hermes the richer view.

6. **Logs tab** — streams events via `Druzhok.Events.subscribe_all/0` from the LogWatcher process tailing container logs. For hermes, the docker log output comes through `docker logs -f` same as every other runtime. **Should work as-is.** `LogWatcher` currently calls `runtime.parse_log_rejection/1` for pairing detection — hermes returns `:ignore` so nothing interesting happens, just raw log streaming. Good.

7. **Errors tab** — reads `CrashLog.recent_for_instance/2`. Populated by `PoolObserver` (pool only) and `LogWatcher`. PoolObserver goes away with Phase 3. LogWatcher's regex-based error detection was for openclaw pool logs. **For non-pool, we probably want LogWatcher to also classify errors, or drop the Errors tab until we have a story.** Lowest risk: leave the tab, accept that it's quiet for the new single-instance path until we add container-level error classification later.

8. **Usage tab** — queries the `usage` table, populated by the LLM proxy controller on every `/v1/chat/completions` call. Agnostic to runtime. **Works.**

9. **SQLite browser** — opens `.db`/`.sqlite` files found in the file browser. Hermes writes `hermes_state.py` SQLite sessions into `/opt/data/sessions/*.db`. Once we fix point 5 (file browser root), the SQLite browser will see them for free.

10. **"Processes" / "Models" / "Settings" / "Errors" top-level pages** — `router.ex:52-57`. Don't touch in this pass. They're per-app-global, not per-bot.

**Outcome of audit:** we need these new behaviour callbacks, added in Phase 2:
- `data_mount_path()` — `/data` default, `/opt/data` for hermes.
- `supports_feature?(:dreaming | :heartbeat | :fallback_models | :group_chat_config)` — add these atoms to the existing callback.
- `file_browser_root(instance)` — default `instance.workspace`, override for hermes.

And these dashboard changes (one PR with Phase 4):
- Register `"hermes"` in `runtime_badge_color/1`.
- Gate Settings sections on `supports_feature?/1`.
- Use `runtime.file_browser_root(instance)` in `FilesTab.update/2`.
- Remove pool sidebar block (also part of Phase 3).

### Phase 5 — Browser tool + filesystem sanity checks

Hermes has Playwright Chromium preinstalled. Two gotchas with running Chromium in a container:

1. **`/dev/shm` size** — default is 64MB, Chromium expects ≥1GB. Fix: `--shm-size=2g` on docker run (or `-v /dev/shm:/dev/shm`, but that's shared with the host). Added to `start_container/5` in Phase 3 step 4 above.

2. **Linux capabilities / user namespaces** — Playwright Chromium may want `CAP_SYS_ADMIN` for sandbox mode; without it, Chromium falls back to `--no-sandbox`, which Playwright handles automatically. Usually not a problem, but if pages fail to load verify with `docker exec druzhok-bot-{name} playwright --version` and a test page load.

3. **File rights — the main concern you called out.** The fix is `--user 1000:1000` (host UID:GID). This means:
   - All files written inside the container to `/opt/data` show up on the host as `igor:igor`.
   - Hermes's entrypoint-created directories (`cron/`, `sessions/`, `logs/`, etc.) are writable by igor on the host.
   - The dashboard Files tab (running as igor under druzhok) can read/edit/delete them.
   - If hermes ever needs root at runtime (it doesn't, as far as I can tell from the code), we'll find out via a startup error and can revisit.
   - One caveat: packages installed at image build time are owned by root in the image. The container user can still *read* them (world-readable) but can't modify `/opt/hermes` itself. That's fine — nothing should modify `/opt/hermes` at runtime.

4. **Network access to the druzhok LLM proxy** — `--network host` means hermes reaches `127.0.0.1:4000` which is where druzhok's Phoenix listens. Already how openclaw and zeroclaw work. Works.

5. **xray outbound proxy** — hermes's outbound HTTP calls to LLM providers go through `OPENAI_BASE_URL` which points at druzhok's proxy, so they egress via druzhok (which already routes through xray on the host). Hermes itself does not need to know about xray. Do NOT set `HTTP_PROXY` / `HTTPS_PROXY` in hermes's env — per CLAUDE.md, this corrupts multipart FormData.

6. **Browser tool telemetry** — hermes's `browser_tool.py` uses Browserbase (cloud service) as default. If you don't set `BROWSERBASE_API_KEY`, browser_tool silently disabled or falls back to Playwright local. Decide what druzhok wants:
   - **v1 default:** no Browserbase key set → hermes falls back to local Playwright. File issue if that path is broken.
   - **Later:** per-tenant Browserbase keys, or one shared key in druzhok config.

### Phase 6 — Rollout and testing

1. **Create a test hermes instance in the dashboard named `hermes-test`.** Use a throwaway telegram bot token. Pre-approve your own user ID.

2. **Verify startup sequence:**
   - `docker logs druzhok-bot-hermes-test` shows hermes starting, connecting to Telegram, connecting to the LLM proxy.
   - `docker inspect druzhok-bot-hermes-test` shows the expected env vars, mount, user, network.
   - `ls -la /home/igor/druzhok-data/v4-instances/hermes-test/` shows files owned by `igor:igor`.
   - Dashboard's container-status badge shows `running`.

3. **Send a test message** from Telegram. Confirm the bot replies and the response is metered in the Usage tab.

4. **Test the allowlist flow:** from an unauthorized Telegram account, send a message. Hermes's pairing flow should respond with a code. The dashboard does NOT mediate this in v1 (noted in Phase 2). Approve manually via `docker exec druzhok-bot-hermes-test hermes pair approve <code>` (or equivalent — verify command).

5. **Test clear history** from Settings. Verify `/opt/data/sessions/` is emptied, bot restarts, new conversation starts fresh.

6. **Test a runtime switch:** change `hermes-test`'s `bot_runtime` from hermes to openclaw in the DB (or via admin dashboard if exposed). Restart. Confirm openclaw takes over with its own config file layout (may leave hermes junk behind in `/opt/data/` — acceptable, runtime-switch is rare and manual).

7. **Decommission the old pool:**
   ```bash
   ssh igor@158.160.78.230 "docker rm -f druzhok-pool-1; \
     for c in \$(docker ps -a --filter name=openclaw-sbx-agent -q); do docker rm -f \$c; done; \
     sudo systemctl restart druzhok"
   ```
   Then for each existing tenant with `bot_runtime=openclaw`: open dashboard → settings → restart. Verify they come up as standalone `druzhok-bot-{name}` containers.

8. **Migrate an existing user to hermes** if desired: update `bot_runtime` in the DB, restart. Allow for the fact that their OpenClaw conversation history in `/data/state/` is gone (hermes uses different session storage under `/opt/data/sessions/`). Warn them.

---

## Open questions / decisions for you

Things I don't have context to decide alone:

1. **Do existing tenants (Igz, igor, vasa, zhora) stay on openclaw, or migrate to hermes?** Migration loses their OpenClaw-era conversation state. If the answer is "gradually migrate," we should support both runtimes side-by-side for a while, which the plan already does.
2. **Should we ship druzhok-owned config.yaml / SOUL.md templates for hermes bots** (Option B in Phase 2) or rely on hermes defaults (Option A)? A gives more control, B is less work. v1 = B, upgrade later.
3. **Browserbase key strategy.** Shared or per-tenant? Not urgent; local Playwright works for most cases.
4. **Dashboard pairing mediation for hermes.** Hermes has its own in-bot pairing flow. If you want druzhok to approve new users via the dashboard like it does for zeroclaw/openclaw, we'd need to read/write hermes's `platforms/pairing/telegram-approved.json` directly. Deferred to v1.1.
5. **Is it okay to remove the `health_path/0` + `health_port/0` behaviour callbacks?** They're dead after pool decommission. Includes grepping every adapter to make sure nothing else uses them.
6. **Docker socket mount for hermes** — I strongly recommend NOT mounting it. If you need hermes to spawn per-tool containers (for isolation of shell commands), that's a separate conversation and a different plan.

---

## Rollback plan

If hermes integration breaks in production:

1. `docker rm -f druzhok-bot-hermes-test` (or whichever is broken).
2. Revert the adapter registration and dashboard changes (git revert the feature commit).
3. OpenClaw tenants already run in the non-pool path (Phase 3). If that path is also broken, revert the pool-decommission commit too; tenants return to pool. The openclaw:latest image is still on the host — nothing is deleted until the user confirms it's safe.
4. Worst case: `docker run` the old pool by hand with the same flags we captured in "Current state snapshot" above.

## Commit topology

Keep these as separate commits so rollback is granular:

1. `feat(runtime): add hermes adapter` — new `hermes.ex`, register in `runtime.ex`, no dashboard changes.
2. `feat(runtime): data_mount_path + feature flags` — new behaviour callbacks, update all adapters, update `bot_manager.ex:start_container`.
3. `feat(dashboard): runtime feature gates in settings tab` — gate dreaming/heartbeat/fallback/group-chat on `supports_feature?/1`.
4. `feat(dashboard): hermes runtime option` — badge color, dropdown verified.
5. `feat(runtime): file_browser_root callback` — FilesTab respects per-runtime roots.
6. `refactor(runtime): openclaw non-pool` — `OpenClaw.pooled?/0 → false`, remove pool branches from `bot_manager.ex`.
7. `refactor(pool): delete pool manager/config/observer` — large delete commit, migrations to drop `pools` table + `pool_id` column.
8. `chore(dashboard): remove pool sidebar block` — cleanup.
9. Remote deployment commits in shell history (not in git): hermes image transfer + pool teardown.

---

## Files that will be touched

**New:**
- `apps/druzhok/lib/druzhok/runtime/hermes.ex`
- `apps/druzhok/test/druzhok/runtime/hermes_test.exs` (unit tests for `env_vars`, `build_allowlist`, `clear_sessions`)
- (optional) `apps/druzhok/priv/runtime_templates/hermes/config.yaml.eex`

**Modified:**
- `apps/druzhok/lib/druzhok/runtime.ex` — register hermes, remove `health_path`/`health_port` callbacks, add `data_mount_path`/`file_browser_root`/expanded `supports_feature?` atoms.
- `apps/druzhok/lib/druzhok/runtime/open_claw.ex` — `pooled?: false`, add `data_mount_path: "/data"`, feature flags return true.
- `apps/druzhok/lib/druzhok/runtime/zero_claw.ex` — add `data_mount_path: "/data"`, feature flags.
- `apps/druzhok/lib/druzhok/runtime/pico_claw.ex` — same.
- `apps/druzhok/lib/druzhok/runtime/null_claw.ex` — same.
- `apps/druzhok/lib/druzhok/bot_manager.ex` — drop pool branches, add `--user` / `--shm-size`, use `data_mount_path/0`.
- `apps/druzhok/lib/druzhok/health_monitor.ex` — no change needed.
- `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — badge color, remove pool sidebar block.
- `apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — feature-flag gates on dreaming/heartbeat/fallback/group-chat.
- `apps/druzhok_web/lib/druzhok_web_web/live/components/files_tab.ex` — use `runtime.file_browser_root/1`.
- `apps/druzhok/priv/repo/migrations/*_drop_pools.exs` (new migration).

**Deleted:**
- `apps/druzhok/lib/druzhok/pool_manager.ex`
- `apps/druzhok/lib/druzhok/pool_config.ex`
- `apps/druzhok/lib/druzhok/pool_observer.ex`
- `apps/druzhok/lib/druzhok/pool.ex`
- `apps/druzhok/test/druzhok/pool_manager_test.exs`
- `apps/druzhok/test/druzhok/pool_config_test.exs`

Approximate diff: +400 lines for hermes + dashboard, −1200 lines for pool removal. Net −800.
