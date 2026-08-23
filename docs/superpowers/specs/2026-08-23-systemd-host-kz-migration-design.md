# Docker-free Hermes hosting on the Kazakhstan box

**Date:** 2026-08-23
**Status:** approved design, awaiting implementation plan

## Goal

Run Druzhok and its Hermes bots on the new PS Cloud server in Almaty
(`195.49.213.8`, Ubuntu 24.04, 2 vCPU / 8 GB / 5 + 50 GB) **without
Docker**. Each bot is a systemd service running as its own Linux user.
Druzhok keeps everything it has today (dashboard, LLM proxy with
budgets, manager bot, bot sites); only the layer that launches and
supervises bots changes. Honcho is removed. Existing bots are migrated
from the Yandex VM after the first bot proves the setup.

Why: the Docker image build + 1 GB transfer was the main friction in the
dev loop, and it exists only because OpenClaw needed a custom image.
Hermes is a Python package; one shared install plus per-user systemd
units gives equivalent isolation for a closed beta and better egress
control than today's `--network host` containers.

## Non-goals

- Firecracker / gVisor. The box has `/dev/kvm`, so this can come later
  without changing Druzhok's interface.
- Mock-LLM contract tests or golden e2e scenarios.
- Keeping Docker, OpenClaw, ZeroClaw, PicoClaw, NullClaw or Honcho code
  paths. They are deleted; git history keeps them.
- Migrating Honcho memory. It is discarded with Honcho.

## Server layout

```
/data                         /dev/sdb, ext4, fstab. All mutable state.
  druzhok/druzhok.db          SQLite (DATABASE_PATH)
  tenants/<name>/             HERMES_HOME. owner bot-<name>:bot-<name>, mode 0700
    workspace/ config.yaml memories/ sessions/ sites/ home/ …
/opt/hermes                   clone of github.com/iforaa/druzhok-hermes (branch main,
                              currently v2026.8.19 + DM-pair guard) + .venv
                              (uv sync --extra all --extra messaging --extra firecrawl)
                              root:root, world-readable, never writable by bots
/home/ubuntu/druzhok          druzhok repo. Phoenix runs as `ubuntu` via druzhok.service,
                              binds 127.0.0.1:4000
/etc/druzhok/<name>.env       per-bot env incl. secrets. root:root 0600
/etc/systemd/system/hermes@.service   template unit
/usr/local/sbin/druzhok-ctl   root helper; sudoers: ubuntu NOPASSWD for this path only
/etc/caddy/Caddyfile          Caddy (apt build with cloudflare DNS module) :443 → 127.0.0.1:4000,
                              wildcard *.oldey.dev via Cloudflare DNS-01 (token in /etc/caddy/env)
```

Linux users `bot-<name>` are system accounts: `useradd -r -M -s
/usr/sbin/nologin -d /data/tenants/<name>`. Hermes runs as that uid;
the Docker-era `HERMES_UID`/gosu remap is gone. `HOME` is
`/data/tenants/<name>/home` as today.

Processes on the box: Elixir (~300 MB), Caddy, N × Hermes gateway
(~300–500 MB each). Budget ~10–12 bots on 8 GB. No Docker, no Honcho,
no WireGuard (Almaty IP reaches OpenRouter, Anthropic, OpenAI and
Telegram directly — verified 2026-08-23).

## Bot isolation

### `hermes@.service`

```ini
[Unit]
Description=Hermes bot %i
After=network-online.target druzhok.service

[Service]
Type=notify
NotifyAccess=all
WatchdogSec=120
User=bot-%i
Group=bot-%i
EnvironmentFile=/etc/druzhok/%i.env
Environment=HERMES_HOME=/data/tenants/%i
Environment=HOME=/data/tenants/%i/home
WorkingDirectory=/data/tenants/%i/workspace
ExecStart=/opt/hermes/.venv/bin/hermes gateway run
Restart=always
RestartSec=5

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/data/tenants/%i
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

MemoryMax=1G
CPUQuota=100%
TasksMax=256

[Install]
WantedBy=multi-user.target
```

`Type=notify` + `WatchdogSec` use Hermes's native
`gateway/systemd_notify.py` (landed between 0.17 and 0.20). Hermes's
`local` terminal backend spawns children inside the unit, so they inherit
every restriction above. bubblewrap is not used.

### `druzhok-ctl`

Bash, ~150 lines, in the repo at `v4/druzhok/ops/druzhok-ctl`, installed
to `/usr/local/sbin/`. Every subcommand validates `<name>` against
`^[a-z0-9][a-z0-9-]{0,30}$` first and refuses otherwise.

| Command | Effect |
|---|---|
| `create <name>` | `useradd` as above; `mkdir -p` data root + `home`, chown, 0700; write `/etc/druzhok/<name>.env` from **stdin**; add nft rules for the uid |
| `update-env <name>` | rewrite the env file from stdin (called on every start so settings changes apply) |
| `start\|stop\|restart <name>` | `systemctl <verb> hermes@<name>`; `stop` also `reset-failed` |
| `status <name>` | prints `active\|activating\|inactive\|failed\|unknown` |
| `stats <name>` | prints `memory_bytes\|cpu_usec` from the unit's cgroup |
| `logs <name> [n]` | `journalctl -u hermes@<name> -n <n> --no-pager -o cat` |
| `exec <name> <args…>` | `runuser -u bot-<name> -- <args…>` with `HERMES_HOME` set; used for `hermes pairing approve` |
| `destroy <name>` | stop, `userdel` (no `-r`), remove env file, drop nft rules. Wiping the data dir stays in Druzhok (`BotManager.safe_to_wipe?`) |

Secrets never appear in argv; the env file is written from stdin.

### Egress (nftables)

Base table installed by bootstrap; `create`/`destroy` add/remove one
uid-keyed set element. Policy per bot uid:

```
allow  tcp → 127.0.0.1:4000            (Druzhok proxy: LLM, STT, search, images)
allow  udp/tcp → :53                   (DNS)
drop   → 169.254.0.0/16                (cloud metadata)
drop   → 127.0.0.0/8, ::1              (no other local services: SSH, Postgres, …)
allow  tcp → :80, :443  counter        (web_fetch, pip, git, user projects)
drop   everything else                 (SMTP, SSH-out, raw ports)
```

LLM metering stays enforced because `OPENAI_BASE_URL` points at the
proxy and upstream provider keys exist only on the proxy. The per-uid
`counter` gives bytes-out per bot for abuse checks (`nft list counters`).

## Druzhok changes

### `Druzhok.Host` behaviour

```elixir
@callback start(name, env :: %{String.t() => String.t()}, data_root) :: :ok | {:error, term}
@callback stop(name) :: :ok
@callback destroy(name) :: :ok
@callback status(name) :: :active | :activating | :inactive | :failed | :unknown
@callback stats(name) :: %{mem_bytes: integer, cpu_usec: integer} | nil
@callback exec(name, [String.t()]) :: {output :: String.t(), exit_code :: integer}
@callback logs(name, lines :: pos_integer) :: String.t()
```

Implementation chosen by `config :druzhok, :host` — `Druzhok.Host.Systemd`
in prod, `Druzhok.Host.Process` in dev/test.

- **`Host.Systemd`** shells out to `sudo /usr/local/sbin/druzhok-ctl …`.
  `start` = `create` if the user doesn't exist yet (idempotent), then
  `update-env` with the env map piped as `KEY=VALUE` lines, then
  `start`. Values are escaped for systemd `EnvironmentFile` quoting.
- **`Host.Process`** spawns `hermes gateway run` as an Erlang `Port`
  under a `DynamicSupervisor`, env from the same map plus
  `HERMES_HOME=<data_root>`. Binary from `HERMES_BIN` env (your local
  venv). `stats` via `ps -o rss,time`. `logs` from a ring buffer of the
  port's stdout. No isolation — dev only; tests use a stub `hermes`
  script.

### `BotManager`

- `start/1`: compute env (`Runtime.base_env` + `runtime.env_vars`), write
  workspace files, `sync_config`, then `Host.start`. `HealthMonitor.register`
  as today. No `LogWatcher`.
- `stop/1`: `Host.stop`. `restart/1` unchanged (global lock).
- `delete/1`: `Host.destroy` then `wipe_data_dir` (existing guard).
- `status/stats/exec` delegate to `Host`. `container_name/1`,
  `host_uid/0`, `host_gid/0`, `start_container`, `stop_container`,
  `status_for_container`, `stats_for_container` removed. Dashboard
  call sites updated.
- `data_root_base/0` default → `/data/tenants` when `DRUZHOK_DATA_ROOT`
  is unset in prod; dev keeps the repo-relative default.

### `Runtime` behaviour

Remove `docker_image/0`, `gateway_command/0`, `data_mount_path/0`. Add
`data_root(instance)`; `Runtime.Hermes` derives `HERMES_HOME`,
`MESSAGING_CWD`, `file_browser_root`, `sync_config` paths from it
instead of the constant `/opt/data`. `env_vars/1` drops `HERMES_UID`,
`HERMES_GID`. `Runtime.proxy_host/0` default → `127.0.0.1`. The
`@runtimes` map keeps only `"hermes"`.

### `HealthMonitor` → probe

Every 60 s per registered bot, in a `Task` with a 20 s timeout:

1. `Host.status(name) == :active`, else `down(unit: status)`.
2. Telegram `getMe` with the bot token, else `degraded(telegram: reason)`.
3. One chat completion through the proxy with the bot's tenant key:
   `model: <instance.model>`, `max_tokens: 1`, `messages: [ping]`, else
   `degraded(llm: status)`. Cost is negligible; it is also what tells
   you a key or budget is dead.
4. `Host.exec(name, ["curl","-m3","-sS","http://127.0.0.1:22"])` must
   fail; success → `degraded(egress_open)`.

State per bot: `healthy | degraded(reasons) | down`, exposed in the
dashboard sidebar. Three consecutive `down` → `BotManager.restart/1`
(current behaviour). Every transition to `degraded`/`down` writes a
`CrashLog` row so `/errors` is the alert feed.

### Deleted

`Runtime.{OpenClaw,ZeroClaw,PicoClaw,NullClaw}`, `Sandbox`,
`Sandbox.{Local,Docker,DockerClient,Firecracker,FirecrackerClient,Protocol}`,
`Instance.Sup`, `Scheduler`, `InstanceWatcher`, `LogWatcher`, `LogPort`,
`HonchoJwt`, `ChatChannel` + `ChatSocket`, `services/sandbox-agent`,
`docker-entrypoint.sh`, `v4/druzhok/workspace-template` (stale copy),
`config/Caddyfile` (replaced by `ops/Caddyfile`), the
`priv/translations.json` leftover, `InstanceDynSup` from the supervision
tree, `sandbox` handling in `InstanceManager`, and the `sandbox_*` /
honcho i18n strings.

Honcho: remove `memory_provider`, `honcho_workspace`, `honcho_token`,
`sync_honcho_config`, `sync_memory_block`'s honcho branch,
`memory_section("honcho")`, the settings-tab UI for it, and the
`honcho-system` instance row (new migration deletes it; SQLite columns
stay, unused). `memory_provider` is no longer written; Hermes builtin
memory is the only option.

### Proxy hardening

- `/v1/audio/transcriptions`, `/v1/audio/speech`, `/v1/responses` and
  `/v2/search` move into the `:llm_api` pipeline, so a tenant key is
  **required** on every proxy route. Hermes already sends it everywhere
  (`OPENAI_API_KEY`, `STT_OPENAI_BASE_URL` + key, `FIRECRAWL_API_KEY`);
  the "optional" auth existed for OpenClaw, which is gone. Requests
  without a valid key get 401 and are never metered or forwarded. The
  probe uses the bot's own tenant key.
- `Auth.require_admin` piped on `/processes`, `/usage`, `/errors`.

### Tests

- `Host.Systemd`: a fake `druzhok-ctl` under `test/support` records
  argv + stdin to a file; assert the exact calls and env serialisation,
  including escaping of values with spaces/quotes.
- `Host.Process`: stub `hermes` script that prints its env and sleeps;
  assert start/status/stop/logs round-trip.
- `HealthMonitor` probe with Bypass for Telegram and the proxy.
- Router test: every `/v1/*` and `/v2/*` route returns 401 without a key.
- The 12 currently failing stale tests are fixed or deleted with the
  code they tested. `mix test` must be green before deploy.

## Ops files (in repo, `v4/druzhok/ops/`)

- `bootstrap.sh` — run once as root on a fresh box: mkfs + mount
  `/dev/sdb` → `/data` (fstab), apt (`caddy` from the Caddy repo with
  the cloudflare module via `caddy add-package`, `nftables`, `uv`,
  `build-essential`, asdf + erlang/elixir at the versions in
  `.tool-versions`), clone `/opt/hermes` + `uv sync`, install
  `hermes@.service`, `druzhok-ctl`, sudoers fragment, nft base table,
  `druzhok.service`, Caddyfile + `/etc/caddy/env` placeholder.
  Idempotent.
- `druzhok-ctl`, `hermes@.service`, `druzhok.service`, `nftables.conf`,
  `sudoers.d/druzhok`, `Caddyfile`.
- `smoke.sh <name>` — creates a throwaway bot through
  `Druzhok.BotManager.create/2` (via `mix run`), waits for `:active`,
  sends a message to it from the operator's Telegram via the manager-bot
  token, expects a reply within 60 s, then `BotManager.delete/1`.
- `export-instances.exs` / `import-instances.exs` — dump instance rows
  (minus honcho fields) to JSON on Yandex, load on KZ.

## Rollout

1. `bootstrap.sh` on the KZ box.
2. Deploy Druzhok: clone, `mix deps.get && mix compile`, `ecto.migrate`,
   seed admin, `systemctl start druzhok`. Enter OpenRouter key and
   manager-bot token in Settings over an SSH tunnel.
3. Create the operator's own bot first. Run `smoke.sh`. Use it for a day.
4. Repoint `oldey.dev` + `*.oldey.dev` on Cloudflare → `195.49.213.8`.
   Caddy obtains the wildcard cert.
5. Migrate remaining bots one at a time: stop the Yandex container,
   `rsync` `/home/igor/druzhok-data/v4-instances/<name>/` →
   `/data/tenants/<name>/`, import the instance row, `BotManager.start`.
   First boot auto-migrates `config.yaml` (backup files are created by
   Hermes).
6. Yandex VM stays up with bots stopped for two weeks as fallback, then
   is decommissioned.

## Hermes updates (replaces the Docker steps in the `update-hermes` skill)

1. On the Mac: snapshot branch, `git fetch upstream --tags`, reset
   `main` to the chosen release tag, re-apply the DM-pair guard, push to
   `iforaa/druzhok-hermes`.
2. On the server: `cd /opt/hermes && git pull && uv sync --extra all
   --extra messaging --extra firecrawl`.
3. `druzhok-ctl restart <operator-bot>`, run `smoke.sh`, then restart the
   others one at a time.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Kernel exploit from a bot → root | systemd hardening above; unattended-upgrades for the kernel; Firecracker later |
| One bot exhausts RAM/CPU/PIDs | `MemoryMax`, `CPUQuota`, `TasksMax`; disk quota on `/data` is a follow-up |
| Bot reaches another bot's proxy budget | Every proxy route requires a tenant key; keys are per bot and live only in that bot's root-owned env file |
| Secrets readable by the bot | The bot can read its own env (it needs the Telegram token); it cannot read `/etc/druzhok/*.env` of others (0600 root) |
| Abuse of hosted sites under `*.oldey.dev` | Existing `website_hosting_enabled` toggle per bot; takedown = toggle off + `BotManager.restart` |
| `druzhok-ctl` bug = root | Name validation, no argv secrets, shellcheck in CI, unit tested with bats is a follow-up |
