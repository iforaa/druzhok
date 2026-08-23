# Systemd Host Backend — Ops & KZ Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the server-side files (`druzhok-ctl`, `hermes@.service`, nftables, sudoers, `druzhok.service`, Caddyfile, `bootstrap.sh`, `smoke.sh`, export/import scripts), bring up the KZ box with them, run the operator's bot there, and migrate the remaining bots from the Yandex VM.

**Architecture:** Everything lives in `v4/druzhok/ops/` and is installed by `bootstrap.sh` (idempotent, run as root). `druzhok-ctl` is the only privileged entry point Druzhok uses (via sudoers). nftables keys egress rules on the bot's uid. Caddy terminates TLS for `oldey.dev` + wildcard and proxies to Phoenix on `127.0.0.1:4000`.

**Tech Stack:** Ubuntu 24.04, systemd 255, nftables, bash (shellcheck-clean), Caddy 2 with `caddy-dns/cloudflare`, `uv`, asdf (erlang/elixir per `.tool-versions`), rsync.

**Spec:** `docs/superpowers/specs/2026-08-23-systemd-host-kz-migration-design.md`
**Depends on:** `docs/superpowers/plans/2026-08-23-systemd-host-code.md` (Druzhok must speak `druzhok-ctl` before Task 5 here).

## Global Constraints

- Server: `ssh ubuntu@195.49.213.8` (passwordless sudo). Hostname `alpha-eridanus`. 2 vCPU / 7.8 GB / `/dev/sda2` 5 GB root / `/dev/sdb` 50 GB raw.
- Bot name regex: `^[a-z0-9][a-z0-9-]{0,30}$`. Linux user `bot-<name>`, unit `hermes@<name>.service`, data `/data/tenants/<name>`, env `/etc/druzhok/<name>.env`.
- `druzhok-ctl` contract (consumed by `Druzhok.Host.Systemd`): `create <name>` / `update-env <name>` read the env file body from **stdin**; `start|stop|restart|destroy <name>`; `status <name>` prints exactly one of `active|activating|inactive|failed|unknown`; `stats <name>` prints `<mem_bytes>|<cpu_usec>`; `logs <name> <n>`; `exec <name> <cmd> [args…]`. Non-zero exit + stderr message on any failure.
- Hermes install: `/opt/hermes`, branch `main` of `git@github.com:iforaa/druzhok-hermes.git` (read via https), `uv sync --extra all --extra messaging --extra firecrawl`.
- Never run anything destructive on the Yandex VM until Task 7; never start a bot on KZ while its Yandex container is running (Telegram single-poller).
- All ops files are shellcheck-clean (`shellcheck -s bash ops/*.sh ops/druzhok-ctl`); install shellcheck locally with `brew install shellcheck` if missing.

---

## File Structure

```
v4/druzhok/ops/
  druzhok-ctl            root helper (bash)
  hermes@.service        systemd template unit
  druzhok.service        Phoenix unit (runs as ubuntu)
  nftables-druzhok.nft   base table; per-uid set populated by druzhok-ctl
  sudoers-druzhok        /etc/sudoers.d/druzhok
  Caddyfile              oldey.dev + *.oldey.dev → 127.0.0.1:4000
  bootstrap.sh           one-shot, idempotent server setup (root)
  smoke.sh               create throwaway bot → Telegram round-trip → delete
  export_instances.exs   Yandex: dump instance rows to JSON
  import_instances.exs   KZ: load instance rows from JSON
```
`config/Caddyfile` (old) is deleted in Task 3.

---

### Task 1: `druzhok-ctl`

**Files:**
- Create: `v4/druzhok/ops/druzhok-ctl`
- Test: local `shellcheck` + a syntax/dry run; functional test on the server in Task 4.

**Interfaces:**
- Produces: the contract in Global Constraints. Env file written with `install -m 0600 -o root -g root`.
- nft integration: adds/removes the bot's uid in set `inet druzhok bot_uids` (defined in Task 2).

- [ ] **Step 1: Write the script**

`v4/druzhok/ops/druzhok-ctl`:
```bash
#!/usr/bin/env bash
# druzhok-ctl — the single privileged entry point Druzhok uses to manage
# per-bot Linux users + systemd units. Invoked as root via sudo.
#
#   create <name>      (env file on stdin)   useradd + data dir + env + nft
#   update-env <name>  (env file on stdin)   rewrite env file
#   start|stop|restart|destroy <name>
#   status <name>      → active|activating|inactive|failed|unknown
#   stats <name>       → <mem_bytes>|<cpu_usec>
#   logs <name> <n>
#   exec <name> <cmd> [args…]                run as the bot user
set -euo pipefail

TENANTS=/data/tenants
ENVDIR=/etc/druzhok
NFT_TABLE="inet druzhok"
NFT_SET=bot_uids

die() { echo "druzhok-ctl: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ $# -ge 2 ] || die "usage: druzhok-ctl <cmd> <name> [args]"

cmd=$1; name=$2; shift 2
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid bot name: $name"

user="bot-$name"
unit="hermes@$name.service"
root="$TENANTS/$name"
envf="$ENVDIR/$name.env"

user_exists() { id -u "$user" >/dev/null 2>&1; }
uid_of()      { id -u "$user"; }

write_env() {
  # stdin → $envf, atomically, root-only. Reject anything that isn't KEY="…" lines.
  local tmp
  tmp=$(mktemp "$ENVDIR/.$name.XXXXXX")
  cat > "$tmp"
  if grep -vqE '^[A-Z_][A-Z0-9_]*=".*"$' "$tmp"; then
    rm -f "$tmp"; die "env file must contain only KEY=\"value\" lines"
  fi
  chmod 0600 "$tmp"; chown root:root "$tmp"
  mv -f "$tmp" "$envf"
}

nft_add() {
  nft add element $NFT_TABLE $NFT_SET "{ $(uid_of) }" 2>/dev/null || true
}
nft_del() {
  local uid; uid=$(uid_of) || return 0
  nft delete element $NFT_TABLE $NFT_SET "{ $uid }" 2>/dev/null || true
}

case "$cmd" in
  create)
    if ! user_exists; then
      useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir "$root" "$user"
    fi
    install -d -m 0700 -o "$user" -g "$user" "$root" "$root/home" "$root/workspace"
    mkdir -p "$ENVDIR"; chmod 0755 "$ENVDIR"
    write_env
    nft_add
    ;;
  update-env)
    user_exists || die "no such bot: $name"
    write_env
    ;;
  start|stop|restart)
    user_exists || die "no such bot: $name"
    [ "$cmd" = stop ] && systemctl reset-failed "$unit" 2>/dev/null || true
    systemctl "$cmd" "$unit"
    ;;
  status)
    if ! user_exists; then echo unknown; exit 0; fi
    st=$(systemctl is-active "$unit" 2>/dev/null || true)
    case "$st" in
      active|activating|inactive|failed) echo "$st";;
      deactivating) echo inactive;;
      *) echo inactive;;
    esac
    ;;
  stats)
    user_exists || die "no such bot: $name"
    cg="/sys/fs/cgroup/system.slice/$unit"
    if [ -r "$cg/memory.current" ]; then
      mem=$(cat "$cg/memory.current")
      cpu=$(awk '/^usage_usec/ {print $2}' "$cg/cpu.stat")
      echo "${mem:-0}|${cpu:-0}"
    else
      echo "0|0"
    fi
    ;;
  logs)
    n=${1:-200}
    [[ "$n" =~ ^[0-9]+$ ]] || die "bad line count"
    journalctl -u "$unit" -n "$n" --no-pager -o cat 2>/dev/null || true
    ;;
  exec)
    user_exists || die "no such bot: $name"
    [ $# -ge 1 ] || die "exec needs a command"
    # Same environment the unit sees, minus systemd-only vars.
    exec runuser -u "$user" -- env -i HOME="$root/home" HERMES_HOME="$root" PATH=/usr/local/bin:/usr/bin:/bin \
      "$(sed -E 's/^([A-Z_][A-Z0-9_]*)="(.*)"$/\1=\2/' "$envf" | tr '\n' ' ')" "$@" 2>&1
    ;;
  destroy)
    if user_exists; then
      systemctl stop "$unit" 2>/dev/null || true
      systemctl reset-failed "$unit" 2>/dev/null || true
      nft_del
      userdel "$user"
    fi
    rm -f "$envf"
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
```
The `exec` branch above is wrong: passing the whole env as one quoted word. Replace it with:
```bash
  exec)
    user_exists || die "no such bot: $name"
    [ $# -ge 1 ] || die "exec needs a command"
    envargs=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key=${line%%=*}; val=${line#*=}; val=${val#\"}; val=${val%\"}
      envargs+=("$key=$val")
    done < "$envf"
    exec runuser -u "$user" -- env -i HOME="$root/home" HERMES_HOME="$root" PATH=/usr/local/bin:/usr/bin:/bin \
      "${envargs[@]}" "$@" 2>&1
    ;;
```
(Values containing `\"` or `\\` are rare in our env — tokens and URLs — and `exec` is only used for `hermes pairing approve` and the egress probe; keep it simple.)

- [ ] **Step 2: Lint**

```bash
chmod +x v4/druzhok/ops/druzhok-ctl
shellcheck -s bash v4/druzhok/ops/druzhok-ctl && bash -n v4/druzhok/ops/druzhok-ctl && echo LINT_OK
```
Expected: `LINT_OK` (fix any SC warnings; `SC2086` on the `$NFT_TABLE` word-split is intentional — add `# shellcheck disable=SC2086` above those two lines).

- [ ] **Step 3: Commit**

`/my-commit` — `ops: add druzhok-ctl root helper`.

---

### Task 2: systemd units, nftables, sudoers

**Files:**
- Create: `v4/druzhok/ops/hermes@.service`, `v4/druzhok/ops/druzhok.service`, `v4/druzhok/ops/nftables-druzhok.nft`, `v4/druzhok/ops/sudoers-druzhok`.

- [ ] **Step 1: `hermes@.service`**

```ini
[Unit]
Description=Hermes bot %i
After=network-online.target druzhok.service
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=all
WatchdogSec=120
User=bot-%i
Group=bot-%i
EnvironmentFile=/etc/druzhok/%i.env
Environment=HERMES_HOME=/data/tenants/%i
Environment=HOME=/data/tenants/%i/home
Environment=PATH=/usr/local/bin:/usr/bin:/bin
WorkingDirectory=/data/tenants/%i/workspace
ExecStart=/opt/hermes/.venv/bin/hermes gateway run
Restart=always
RestartSec=5
TimeoutStartSec=300
KillMode=mixed

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/data/tenants/%i
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=

MemoryMax=1G
MemoryHigh=800M
CPUQuota=100%
TasksMax=256

[Install]
WantedBy=multi-user.target
```
If Hermes's `systemd_notify` turns out not to send `READY=1` in `gateway run` mode (check on the server in Task 4: `journalctl -u hermes@<name>` shows "start operation timed out"), change `Type=notify` → `Type=simple` and drop `WatchdogSec`/`NotifyAccess`.

- [ ] **Step 2: `druzhok.service`**

```ini
[Unit]
Description=Druzhok orchestrator (Phoenix)
After=network-online.target
Wants=network-online.target

[Service]
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/druzhok/v4/druzhok
EnvironmentFile=/etc/druzhok/druzhok.env
Environment=MIX_ENV=prod PHX_SERVER=true PORT=4000 DRUZHOK_HOST=systemd
Environment=DATABASE_PATH=/data/druzhok/druzhok.db DRUZHOK_DATA_ROOT=/data/tenants LLM_PROXY_HOST=127.0.0.1
ExecStart=/bin/bash -lc '. /home/ubuntu/.asdf/asdf.sh && exec mix phx.server'
Restart=always
RestartSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
```
`/etc/druzhok/druzhok.env` (created by bootstrap, 0600 ubuntu): `SECRET_KEY_BASE=…`, `PHX_HOST=oldey.dev`, `OPENROUTER_API_KEY=…` (can be blank — the dashboard setting is also honoured).

- [ ] **Step 3: `nftables-druzhok.nft`**

```
#!/usr/sbin/nft -f
# Egress policy for bot users. druzhok-ctl adds each bot's uid to @bot_uids.
table inet druzhok {
  set bot_uids { type uid; flags interval; }

  chain output {
    type filter hook output priority 0; policy accept;

    meta skuid != @bot_uids accept

    # Druzhok proxy
    ip daddr 127.0.0.1 tcp dport 4000 accept
    # DNS
    udp dport 53 accept
    tcp dport 53 accept
    # cloud metadata + any other local service
    ip daddr 169.254.0.0/16 drop
    ip daddr 127.0.0.0/8 drop
    ip6 daddr ::1 drop
    # general web, counted per uid via the meter below
    tcp dport { 80, 443 } meter bot_web { meta skuid counter } accept
    counter drop
  }
}
```
Loaded by `nft -f` from `/etc/nftables.d/druzhok.nft` (bootstrap appends an `include` to `/etc/nftables.conf`). Per-uid bytes: `sudo nft list meter inet druzhok bot_web`.

- [ ] **Step 4: `sudoers-druzhok`**

```
ubuntu ALL=(root) NOPASSWD: /usr/local/sbin/druzhok-ctl
Defaults!/usr/local/sbin/druzhok-ctl !requiretty
```
Validate locally: `visudo -cf v4/druzhok/ops/sudoers-druzhok` (macOS has `visudo`).

- [ ] **Step 5: Lint + commit**

```bash
visudo -cf v4/druzhok/ops/sudoers-druzhok && systemd-analyze --help >/dev/null 2>&1 || true
```
(`systemd-analyze verify` is Linux-only; it runs in Task 4.) `/my-commit` — `ops: hermes@ template unit, druzhok unit, nftables egress policy, sudoers`.

---

### Task 3: Caddyfile, `bootstrap.sh`

**Files:**
- Create: `v4/druzhok/ops/Caddyfile`, `v4/druzhok/ops/bootstrap.sh`
- Delete: `v4/druzhok/config/Caddyfile`

- [ ] **Step 1: Caddyfile**

```
{
  email igor.n.kuz@gmail.com
}

oldey.dev, *.oldey.dev {
  tls {
    dns cloudflare {env.CLOUDFLARE_API_TOKEN}
  }
  encode zstd gzip
  reverse_proxy 127.0.0.1:4000
}
```
The BotSite plug in Phoenix handles `<bot>.oldey.dev` routing, so one site block is enough. `/etc/caddy/env` holds `CLOUDFLARE_API_TOKEN=…` (Zone → DNS → Edit for `oldey.dev`); bootstrap adds `EnvironmentFile=/etc/caddy/env` via a systemd drop-in.

- [ ] **Step 2: `bootstrap.sh`**

```bash
#!/usr/bin/env bash
# One-shot, idempotent server setup for Druzhok on Ubuntu 24.04. Run as root:
#   sudo bash ops/bootstrap.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")" && pwd)
HERMES_REPO=https://github.com/iforaa/druzhok-hermes.git
DATA_DEV=/dev/sdb

step() { echo; echo "==> $*"; }

step "data disk → /data"
if ! blkid "$DATA_DEV" >/dev/null 2>&1; then mkfs.ext4 -L druzhok-data "$DATA_DEV"; fi
mkdir -p /data
grep -q " /data " /etc/fstab || echo "LABEL=druzhok-data /data ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /data || mount /data
install -d -m 0755 /data/tenants
install -d -m 0750 -o ubuntu -g ubuntu /data/druzhok

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q git curl build-essential nftables unzip \
  libssl-dev libncurses-dev autoconf m4 libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev \
  libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils \
  python3 python3-venv ffmpeg unattended-upgrades debian-keyring debian-archive-keyring apt-transport-https
command -v uv >/dev/null || { curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; }

step "caddy (with cloudflare dns module)"
if ! command -v caddy >/dev/null; then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q && apt-get install -y -q caddy
fi
caddy list-modules 2>/dev/null | grep -q dns.providers.cloudflare || caddy add-package github.com/caddy-dns/cloudflare
install -m 0644 "$OPS/Caddyfile" /etc/caddy/Caddyfile
[ -f /etc/caddy/env ] || { echo "CLOUDFLARE_API_TOKEN=CHANGE_ME" > /etc/caddy/env; chmod 0600 /etc/caddy/env; }
mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/env\n' > /etc/systemd/system/caddy.service.d/env.conf

step "hermes → /opt/hermes"
if [ ! -d /opt/hermes/.git ]; then git clone "$HERMES_REPO" /opt/hermes; fi
( cd /opt/hermes && git fetch -q origin && git reset -q --hard origin/main \
  && uv sync --frozen --extra all --extra messaging --extra firecrawl )
chown -R root:root /opt/hermes; chmod -R a+rX /opt/hermes

step "druzhok-ctl + units + sudoers + nftables"
install -m 0755 "$OPS/druzhok-ctl" /usr/local/sbin/druzhok-ctl
install -m 0644 "$OPS/hermes@.service" /etc/systemd/system/hermes@.service
install -m 0644 "$OPS/druzhok.service" /etc/systemd/system/druzhok.service
install -m 0440 "$OPS/sudoers-druzhok" /etc/sudoers.d/druzhok
visudo -cf /etc/sudoers.d/druzhok
mkdir -p /etc/druzhok /etc/nftables.d
install -m 0644 "$OPS/nftables-druzhok.nft" /etc/nftables.d/druzhok.nft
grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
systemctl enable --now nftables
nft -f /etc/nftables.d/druzhok.nft
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/hermes@.service /etc/systemd/system/druzhok.service || true

step "druzhok env"
if [ ! -f /etc/druzhok/druzhok.env ]; then
  cat > /etc/druzhok/druzhok.env <<EOF
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
PHX_HOST=oldey.dev
OPENROUTER_API_KEY=
EOF
  chown ubuntu:ubuntu /etc/druzhok/druzhok.env; chmod 0600 /etc/druzhok/druzhok.env
fi

step "asdf + erlang/elixir for ubuntu (per .tool-versions)"
TV=/home/ubuntu/druzhok/v4/druzhok/.tool-versions
if [ -f "$TV" ]; then
  sudo -u ubuntu -H bash -lc '
    set -e
    [ -d ~/.asdf ] || git clone -q https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
    . ~/.asdf/asdf.sh
    asdf plugin add erlang 2>/dev/null || true
    asdf plugin add elixir 2>/dev/null || true
    cd ~/druzhok/v4/druzhok && asdf install
  '
else
  echo "!! clone the druzhok repo to /home/ubuntu/druzhok first, then re-run for asdf"
fi

echo; echo "bootstrap done. Next: put the Cloudflare token in /etc/caddy/env, then 'systemctl enable --now caddy druzhok'."
```
Check the repo has a `.tool-versions` (`ls v4/druzhok/.tool-versions`); if not, create one matching the Yandex VM (`ssh igor@10.129.0.19 'cat ~/druzhok/v4/druzhok/.tool-versions 2>/dev/null; asdf current'`).

- [ ] **Step 3: Lint, delete old Caddyfile, commit**

```bash
shellcheck -s bash v4/druzhok/ops/bootstrap.sh && bash -n v4/druzhok/ops/bootstrap.sh && echo OK
git rm -q v4/druzhok/config/Caddyfile
```
`/my-commit` — `ops: bootstrap.sh and Caddyfile for the KZ box`.

---

### Task 4: Bring up the KZ box (no bots yet)

**Files:** none new; server work.

- [ ] **Step 1: Clone repo, run bootstrap**

```bash
ssh ubuntu@195.49.213.8 'git clone https://github.com/<your-druzhok-remote> ~/druzhok 2>/dev/null || (cd ~/druzhok && git pull --ff-only)'
```
(Find the remote: `git -C /Users/igorkuznetsov/Documents/druzhok remote -v`. If the druzhok repo is private and the box has no deploy key, `rsync -a --exclude v4/hermes-agent --exclude 'v4/*claw' --exclude '**/_build' --exclude '**/deps' --exclude node_modules /Users/igorkuznetsov/Documents/druzhok/ ubuntu@195.49.213.8:~/druzhok/` instead, and note it.)
```bash
ssh ubuntu@195.49.213.8 'sudo bash ~/druzhok/v4/druzhok/ops/bootstrap.sh' 2>&1 | tail -40
```
Expected: ends with `bootstrap done`. Erlang compile takes ~15–25 min on 2 vCPU — run with `run_in_background` and a 600 s timeout in chunks, or `nohup … &` and poll `tail -f`.

- [ ] **Step 2: Verify the pieces independently**

```bash
ssh ubuntu@195.49.213.8 '
  df -h /data | tail -1
  /opt/hermes/.venv/bin/hermes --version
  sudo systemd-analyze verify /etc/systemd/system/hermes@.service && echo UNIT_OK
  sudo nft list table inet druzhok | head -20
  sudo -n /usr/local/sbin/druzhok-ctl status nothing-here
  . ~/.asdf/asdf.sh && elixir --version | tail -1
'
```
Expected: `/data` mounted ~49G, a hermes version string, `UNIT_OK`, the nft table, `unknown`, Elixir version.

- [ ] **Step 3: Functional test of `druzhok-ctl` with a scratch user**

```bash
ssh ubuntu@195.49.213.8 '
  printf '"'"'FOO="bar"\n'"'"' | sudo druzhok-ctl create ctltest
  id bot-ctltest && ls -ld /data/tenants/ctltest && sudo cat /etc/druzhok/ctltest.env
  sudo druzhok-ctl status ctltest
  sudo druzhok-ctl exec ctltest sh -c "echo FOO=\$FOO HERMES_HOME=\$HERMES_HOME"
  sudo druzhok-ctl exec ctltest curl -m3 -sS -o /dev/null http://127.0.0.1:22; echo "egress-to-22 exit=$?  (expect non-zero)"
  sudo druzhok-ctl exec ctltest curl -m5 -sS -o /dev/null -w "%{http_code}\n" https://openrouter.ai/api/v1/models
  sudo nft list set inet druzhok bot_uids
  sudo druzhok-ctl destroy ctltest; id bot-ctltest 2>&1 | tail -1
'
```
Expected: user + 0700 dir + env, `inactive`, `FOO=bar HERMES_HOME=/data/tenants/ctltest`, egress-to-22 non-zero, `200` from OpenRouter, uid in set, then `no such user`.

- [ ] **Step 4: Deploy Druzhok**

```bash
ssh ubuntu@195.49.213.8 '
  cd ~/druzhok/v4/druzhok && . ~/.asdf/asdf.sh
  mix local.hex --force && mix local.rebar --force
  MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile 2>&1 | tail -3
  MIX_ENV=prod mix assets.deploy 2>&1 | tail -2
  DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix ecto.create && DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix ecto.migrate 2>&1 | tail -3
  DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix run apps/druzhok/priv/repo/seeds.exs 2>&1 | tail -2
  sudo systemctl enable --now druzhok && sleep 8 && systemctl is-active druzhok && curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/login
'
```
Expected: `active`, `200`. Check the seeds file for the admin user/password it creates (`grep -n "email\|password" apps/druzhok/priv/repo/seeds.exs`) and tell the user.

- [ ] **Step 5: Settings via SSH tunnel**

Tell the user: `ssh -L 4001:127.0.0.1:4000 ubuntu@195.49.213.8`, open `http://localhost:4001`, log in, enter OpenRouter key and the manager-bot token in Settings (the session cookie is `secure: true` — if login doesn't stick over plain http, set `secure: false` when `PHX_HOST` is unset in `endpoint.ex`, or just wait for Caddy/DNS).

- [ ] **Step 6: Record in memory**

Write `~/.claude/projects/-Users-igorkuznetsov-Documents-druzhok/memory/reference_kz_server.md` (type: reference): host `ubuntu@195.49.213.8`, PS Cloud Almaty, layout `/data`, `/opt/hermes`, `druzhok-ctl`, no Docker. Add the index line to `MEMORY.md`. Mark `reference_yandex_cloud.md` as legacy.

---

### Task 5: `smoke.sh` + operator's bot

**Files:**
- Create: `v4/druzhok/ops/smoke.sh`

- [ ] **Step 1: Write `smoke.sh`**

```bash
#!/usr/bin/env bash
# smoke.sh <bot-name> [chat_id]
# Verifies a bot end-to-end: unit active, Telegram getMe ok, proxy ping ok,
# egress locked, and (if chat_id given) a real message round-trip.
set -euo pipefail
name=${1:?bot name}; chat=${2:-}
cd "$(dirname "$0")/.."
. ~/.asdf/asdf.sh 2>/dev/null || true
export DATABASE_PATH=${DATABASE_PATH:-/data/druzhok/druzhok.db} MIX_ENV=prod DRUZHOK_HOST=systemd LLM_PROXY_HOST=127.0.0.1

echo "== unit"; sudo druzhok-ctl status "$name" | tee /dev/stderr | grep -qx active

echo "== probe"
mix run --no-start -e '
  Application.ensure_all_started(:druzhok)
  inst = Druzhok.Repo.get_by!(Druzhok.Instance, name: System.get_env("SMOKE_NAME"))
  IO.inspect(Druzhok.HealthMonitor.Probe.run(inst), label: "probe")
' 2>/dev/null | grep -q 'probe: {:healthy' || { echo "probe not healthy"; exit 1; }

if [ -n "$chat" ]; then
  echo "== telegram round-trip"
  token=$(sudo sed -nE 's/^TELEGRAM_BOT_TOKEN="(.*)"$/\1/p' "/etc/druzhok/$name.env")
  before=$(curl -s "https://api.telegram.org/bot$token/getUpdates?offset=-1" | python3 -c 'import sys,json; u=json.load(sys.stdin)["result"]; print(u[-1]["update_id"] if u else 0)')
  mgr=$(mix run --no-start -e 'Application.ensure_all_started(:druzhok); IO.puts(Druzhok.Settings.get("manager_bot_token") || "")' 2>/dev/null | tail -1)
  [ -n "$mgr" ] || { echo "no manager bot token; skipping round-trip"; exit 0; }
  # The manager bot DMs the operator chat with a prompt the operator's bot is expected to answer.
  curl -s "https://api.telegram.org/bot$mgr/sendMessage" -d chat_id="$chat" -d text="smoke: reply with the single word pong" >/dev/null
  echo "sent; waiting up to 60s for the bot to reply in chat $chat (watch Telegram)"
  sleep 60
  echo "check the chat manually — automated read-back needs a user session (not a bot token)."
fi
echo "SMOKE OK"
```
Note: a bot cannot read another bot's messages, so the round-trip is semi-manual: the script asserts the measurable parts (unit/probe) and nudges the chat; the human confirms the reply. Export `SMOKE_NAME="$name"` before the probe line (`export SMOKE_NAME=$name`).

- [ ] **Step 2: Create the operator's bot and run it**

Via the dashboard (SSH tunnel) create bot `igor` (or your preferred name) with a Telegram token. Then:
```bash
ssh ubuntu@195.49.213.8 'sudo druzhok-ctl status igor; sudo druzhok-ctl logs igor 40'
ssh ubuntu@195.49.213.8 'cd ~/druzhok/v4/druzhok && bash ops/smoke.sh igor'
```
If the unit times out on start (`Type=notify` without READY) apply the fallback from Task 2 Step 1 (`Type=simple`), `sudo systemctl daemon-reload`, restart. If Hermes complains about config keys, read `/data/tenants/igor/config.yaml.bak-*` vs the new one — auto-migration runs on first boot.

- [ ] **Step 3: Commit**

`/my-commit` — `ops: smoke.sh`.

---

### Task 6: DNS cutover

**Files:** none.

- [ ] **Step 1: Cloudflare** (user does this): A `oldey.dev` → `195.49.213.8`, A `*.oldey.dev` → `195.49.213.8`, proxy status **DNS only** (grey cloud) so Caddy can do DNS-01 and serve the wildcard directly; create an API token with Zone:DNS:Edit for `oldey.dev`.

- [ ] **Step 2: Token + Caddy**

```bash
ssh ubuntu@195.49.213.8 'sudo sed -i "s/^CLOUDFLARE_API_TOKEN=.*/CLOUDFLARE_API_TOKEN=<token>/" /etc/caddy/env && sudo systemctl daemon-reload && sudo systemctl enable --now caddy && sleep 20 && sudo journalctl -u caddy -n 20 --no-pager | grep -iE "certificate obtained|error" ; curl -sI https://oldey.dev/login | head -1'
```
Expected: `certificate obtained successfully` ×2 (apex + wildcard), `HTTP/2 200`.

---

### Task 7: Migrate the remaining bots from Yandex

**Files:**
- Create: `v4/druzhok/ops/export_instances.exs`, `v4/druzhok/ops/import_instances.exs`

- [ ] **Step 1: Export/import scripts**

`export_instances.exs`:
```elixir
# mix run --no-start ops/export_instances.exs > instances.json   (on the old host)
Application.ensure_all_started(:druzhok)
fields = ~w(name telegram_token model workspace active heartbeat_interval owner_telegram_id timezone api_key
            daily_token_limit dream_hour language tenant_key bot_runtime on_demand_model mention_only reject_message
            welcome_message allowed_telegram_ids allowed_telegram_chats allow_all_telegram_users trigger_name image_model
            audio_model embedding_model heartbeat_active_start heartbeat_active_end heartbeat_target fallback_models dreaming
            group_sessions_per_user group_shared_memory website_hosting_enabled daily_budget_cents image_gen_enabled image_gen_model)a
rows =
  Druzhok.InstanceManager.list()
  |> Enum.map(fn i -> i |> Map.from_struct() |> Map.take(fields) |> Map.put(:bot_runtime, "hermes") end)
IO.puts(Jason.encode!(rows, pretty: true))
```
`import_instances.exs`:
```elixir
# DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix run --no-start ops/import_instances.exs instances.json
Application.ensure_all_started(:druzhok)
[path] = System.argv()
for attrs <- path |> File.read!() |> Jason.decode!() do
  name = attrs["name"]
  attrs = Map.put(attrs, "workspace", "/data/tenants/#{name}/workspace") |> Map.put("active", false)
  case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
    nil -> %Druzhok.Instance{} |> Druzhok.Instance.changeset(attrs) |> Druzhok.Repo.insert!()
    _ -> IO.puts("skip existing #{name}")
  end
  IO.puts("imported #{name}")
end
```
Commit: `/my-commit` — `ops: instance export/import scripts`.

- [ ] **Step 2: Export on Yandex, import on KZ**

```bash
ssh igor@10.129.0.19 'cd ~/druzhok/v4/druzhok && . ~/.asdf/asdf.sh && git pull --ff-only && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix run --no-start ops/export_instances.exs' > /private/tmp/claude-501/-Users-igorkuznetsov-Documents-druzhok/547f5878-fa7f-442c-b516-edf8962ad9fa/scratchpad/instances.json
scp /private/tmp/claude-501/-Users-igorkuznetsov-Documents-druzhok/547f5878-fa7f-442c-b516-edf8962ad9fa/scratchpad/instances.json ubuntu@195.49.213.8:/tmp/instances.json
ssh ubuntu@195.49.213.8 'cd ~/druzhok/v4/druzhok && . ~/.asdf/asdf.sh && DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix run --no-start ops/import_instances.exs /tmp/instances.json && rm /tmp/instances.json'
```
(Exclude the operator's bot if it already exists on KZ — the script skips existing names.)

- [ ] **Step 3: Per bot — stop on Yandex, copy data, start on KZ**

For each `<name>` (one at a time; confirm with the user which order):
```bash
ssh igor@10.129.0.19 "docker update --restart=no druzhok-bot-<name>; docker stop druzhok-bot-<name>"
ssh igor@10.129.0.19 "sudo tar -C /home/igor/druzhok-data/v4-instances/<name> -cf - ." | ssh ubuntu@195.49.213.8 "sudo mkdir -p /data/tenants/<name> && sudo tar -C /data/tenants/<name> -xf - && sudo rm -f /data/tenants/<name>/honcho.json"
ssh ubuntu@195.49.213.8 'cd ~/druzhok/v4/druzhok && . ~/.asdf/asdf.sh && DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod DRUZHOK_HOST=systemd LLM_PROXY_HOST=127.0.0.1 mix run --no-start -e "Application.ensure_all_started(:druzhok); IO.inspect(Druzhok.BotManager.start(\"<name>\"))"'
ssh ubuntu@195.49.213.8 'sleep 45; sudo druzhok-ctl status <name>; sudo druzhok-ctl logs <name> 20; cd ~/druzhok/v4/druzhok && bash ops/smoke.sh <name>'
```
`BotManager.start` → `Host.Systemd.start` → `druzhok-ctl create` chowns the copied tree to `bot-<name>` (add `chown -R "$user:$user" "$root"` to the `create` branch of `druzhok-ctl` if the `install -d` alone leaves copied files owned by root — it will; make that change in Task 1's script and re-install with `sudo install -m 0755 ops/druzhok-ctl /usr/local/sbin/`).

- [ ] **Step 4: Fallback window**

Leave the Yandex VM running with containers stopped for 14 days. Record the date in memory `reference_kz_server.md` ("Yandex decommission after 2026-09-XX"). Then remove `reference_yandex_cloud.md`, `project_wireguard_tunnel.md`, `project_wg_inbound_web_asymmetric.md`, `project_caddyfile_prod_drift.md`, `project_honcho_*.md` from memory.

---

## Self-Review

**Spec coverage:** layout (T3/T4), unit + hardening (T2), `druzhok-ctl` contract incl. stdin secrets and name validation (T1), nftables policy incl. metadata/loopback drops + per-uid counters (T2), Caddy/Cloudflare wildcard (T3/T6), bootstrap (T3/T4), smoke (T5), export/import + per-bot migration with single-poller rule (T7), fallback window (T7), Hermes install `--extra firecrawl` (T3). Risks table: `MemoryMax/CPUQuota/TasksMax` in unit; kernel updates via `unattended-upgrades` (T3 packages); chown-on-create fix noted in T7.

**Interfaces vs code plan:** `status` words, `stats` `mem|cpu` format, stdin for `create`/`update-env`, `exec` semantics and `logs <n>` all match `Druzhok.Host.Systemd` in the code plan. `druzhok.service` sets `DRUZHOK_HOST=systemd`, `DRUZHOK_DATA_ROOT=/data/tenants`, `LLM_PROXY_HOST=127.0.0.1` as the code plan's `runtime.exs` expects.

**Placeholders:** `<token>`, `<name>`, `<your-druzhok-remote>` are operator inputs, resolved at execution; no TBDs.
