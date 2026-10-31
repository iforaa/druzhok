#!/usr/bin/env bash
# One-shot, idempotent server setup for Druzhok on Ubuntu 24.04. Run as root:
#   sudo bash ops/bootstrap.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")" && pwd)
HERMES_REPO=https://github.com/iforaa/druzhok-hermes.git
DATA_DEV=${DATA_DEV:-/dev/sdb}
ASDF_VERSION=v0.14.1
# The root disk is only 5 GB: big trees live on /data behind symlinks.
HERMES_DIR=/data/opt/hermes          # /opt/hermes -> here
ASDF_DIR=/data/home-ubuntu/.asdf     # /home/ubuntu/.asdf -> here

step() { echo; echo "==> $*"; }

step "data disk → /data"
if [ -b "$DATA_DEV" ]; then
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then mkfs.ext4 -q -L druzhok-data "$DATA_DEV"; fi
  mkdir -p /data
  grep -q " /data " /etc/fstab || echo "LABEL=druzhok-data /data ext4 defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q /data || mount /data
else
  echo "!! $DATA_DEV not found; using root filesystem for /data"
  mkdir -p /data
fi
install -d -m 0755 /data/tenants /data/opt
install -d -m 0750 -o ubuntu -g ubuntu /data/druzhok
install -d -o ubuntu -g ubuntu /data/home-ubuntu "$ASDF_DIR"
[ -L /opt/hermes ] || ln -sfn "$HERMES_DIR" /opt/hermes
[ -L /home/ubuntu/.asdf ] || { rm -rf /home/ubuntu/.asdf; sudo -u ubuntu ln -sfn "$ASDF_DIR" /home/ubuntu/.asdf; }

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends git curl build-essential nftables unzip acl sqlite3 \
  libssl-dev libncurses-dev autoconf m4 \
  python3 python3-venv ffmpeg unattended-upgrades debian-keyring debian-archive-keyring apt-transport-https
apt-get clean
command -v uv >/dev/null || { curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; }

step "caddy (with cloudflare dns module)"
if ! command -v caddy >/dev/null; then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q && apt-get install -y -q caddy
fi
caddy list-modules 2>/dev/null | grep -q dns.providers.cloudflare || caddy add-package github.com/caddy-dns/cloudflare
install -m 0644 "$OPS/Caddyfile" /etc/caddy/Caddyfile
[ -f /etc/caddy/env ] || { echo "CLOUDFLARE_API_TOKEN=CHANGE_ME" > /etc/caddy/env; chmod 0600 /etc/caddy/env; }
mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/env\n' > /etc/systemd/system/caddy.service.d/env.conf
systemctl disable --now caddy >/dev/null 2>&1 || true   # enabled later, once the CF token is in place

step "hermes → /opt/hermes"
# The tree is normally rsynced from the operator's machine (update-hermes skill);
# fall back to a clone only when nothing is there yet.
if [ ! -f "$HERMES_DIR/pyproject.toml" ]; then git clone -q --depth 1 "$HERMES_REPO" "$HERMES_DIR"; fi
# hermes >= 0.22 runs on Python 3.14 (its uv.lock resolves only for 3.14), which
# uv installs under /data/opt/uv-python; Ubuntu's python3 is too old.
( cd "$HERMES_DIR" && UV_CACHE_DIR=/data/opt/uv-cache UV_PYTHON_INSTALL_DIR=/data/opt/uv-python uv sync --frozen --python 3.14 --extra all --extra messaging --extra firecrawl --extra mnemosyne 2>&1 | tail -2 )
"$HERMES_DIR/.venv/bin/python" "$(dirname "$0")/patch-mnemosyne.py" "$HERMES_DIR"
# Bots run under ProtectSystem=strict and cannot write __pycache__: precompile.
"$HERMES_DIR/.venv/bin/python" -m compileall -q -j0 -x '/(tests?|node_modules)/' "$HERMES_DIR" >/dev/null || true
# The same for uv's standard library, which the venv only links to.
"$HERMES_DIR/.venv/bin/python" -m compileall -q -j0 -x '/(tests?|node_modules)/' "$("$HERMES_DIR/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')" >/dev/null || true
chown -R root:root "$HERMES_DIR"; chmod -R a+rX "$HERMES_DIR" /data/opt/uv-python

step "fetch worker venv (trafilatura + pymupdf for druzhok's page reader)"
apt-get install -y -q --no-install-recommends python3-venv >/dev/null
python3 -m venv /opt/druzhok-fetch/.venv
/opt/druzhok-fetch/.venv/bin/pip install -q -r "$OPS/../apps/druzhok/priv/fetch-worker/requirements.txt"
mkdir -p /etc/druzhok
grep -q '^FETCH_WORKER_BIN=' /etc/druzhok/druzhok.env 2>/dev/null || echo 'FETCH_WORKER_BIN=/opt/druzhok-fetch/.venv/bin/python' >> /etc/druzhok/druzhok.env

step "druzhok-ctl + units + sudoers + nftables"
install -m 0755 "$OPS/druzhok-ctl" /usr/local/sbin/druzhok-ctl
install -m 0644 "$OPS/hermes@.service" /etc/systemd/system/hermes@.service
install -m 0644 "$OPS/system-hermes.slice" /etc/systemd/system/system-hermes.slice
install -m 0644 "$OPS/druzhok.service" /etc/systemd/system/druzhok.service
install -m 0440 "$OPS/sudoers-druzhok" /etc/sudoers.d/druzhok
visudo -cf /etc/sudoers.d/druzhok
mkdir -p /etc/nftables.d
install -m 0644 "$OPS/nftables-druzhok.nft" /etc/nftables.d/druzhok.nft
grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
systemctl enable --now nftables
nft list table inet druzhok >/dev/null 2>&1 && nft delete table inet druzhok
nft -f /etc/nftables.d/druzhok.nft
# A reloaded table starts with an empty set, which means open egress: put
# every existing bot uid back before anything else runs.
for uid in $(getent passwd | awk -F: '/^bot-/ {print $3}'); do
  nft add element inet druzhok bot_uids "{ $uid }"
done
# ...and each bot's { uid . webhook port }, from the env file druzhok wrote.
for envf in /etc/druzhok/*.env; do
  name=$(basename "$envf" .env)
  uid=$(id -u "bot-$name" 2>/dev/null) || continue
  port=$(sed -n 's/^TELEGRAM_WEBHOOK_PORT="\([0-9]\{1,5\}\)"$/\1/p' "$envf" | head -n 1)
  if [ -n "$port" ]; then nft add element inet druzhok bot_webhook "{ $uid . $port }"; fi
done
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/hermes@.service /etc/systemd/system/druzhok.service || true

step "panel save script"
# Runs as each bot's uid (Druzhok.Panel.Editor): root's, so no bot can change it.
# The deploy recipe in CLAUDE.md repeats this; ops/smoke.sh fails on a stale copy.
install -d -m 0755 -o root -g root /usr/local/lib/druzhok
install -m 0644 -o root -g root "$OPS/../apps/druzhok/priv/panel-save/save.py" /usr/local/lib/druzhok/panel-save.py

step "druzhok env"
# Single source of prod env for druzhok.service, druzhok-run.sh and smoke.sh.
# Secrets are generated once; the fixed keys are (re)asserted on every run.
ENVF=/etc/druzhok/druzhok.env
# The fetch worker step above may already have created the file, so look for the key.
if ! grep -q '^SECRET_KEY_BASE=' "$ENVF" 2>/dev/null; then
  printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 48 | tr -d '\n')" >> "$ENVF"
  grep -q '^PHX_HOST=' "$ENVF" || echo 'PHX_HOST=druzhok.oldey.dev' >> "$ENVF"
fi
while IFS='=' read -r k v; do
  grep -q "^$k=" "$ENVF" || echo "$k=$v" >> "$ENVF"
done <<EOT
MIX_ENV=prod
DRUZHOK_HOST=systemd
DATABASE_PATH=/data/druzhok/druzhok.db
HEX_HOME=/data/home-ubuntu/.hex
MIX_HOME=/data/home-ubuntu/.mix
EOT
chown ubuntu:ubuntu "$ENVF"; chmod 0600 "$ENVF"

step "asdf + erlang/elixir for ubuntu (per .tool-versions)"
TV=/home/ubuntu/druzhok/.tool-versions
if [ -f "$TV" ]; then
  sudo -u ubuntu -H bash -lc "
    set -e
    [ -d ~/.asdf/.git ] || git clone -q https://github.com/asdf-vm/asdf.git ~/.asdf --branch $ASDF_VERSION
    . ~/.asdf/asdf.sh
    asdf plugin add erlang 2>/dev/null || true
    asdf plugin add elixir 2>/dev/null || true
    mkdir -p /data/home-ubuntu/tmp && export TMPDIR=/data/home-ubuntu/tmp
    cd ~/druzhok && KERL_CONFIGURE_OPTIONS='--without-wx --without-javac --without-odbc --without-debugger --without-observer --without-et' KERL_BUILD_DOCS=no KERL_BUILD_DIR=/data/home-ubuntu/kerl-build asdf install
  "
else
  echo "!! clone the druzhok repo to /home/ubuntu/druzhok first, then re-run for asdf"
fi

echo; echo "bootstrap done. Next: put the Cloudflare token in /etc/caddy/env, then 'systemctl enable --now caddy druzhok'."
