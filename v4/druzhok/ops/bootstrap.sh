#!/usr/bin/env bash
# One-shot, idempotent server setup for Druzhok on Ubuntu 24.04. Run as root:
#   sudo bash ops/bootstrap.sh
set -euo pipefail
OPS=$(cd "$(dirname "$0")" && pwd)
HERMES_REPO=https://github.com/iforaa/druzhok-hermes.git
DATA_DEV=${DATA_DEV:-/dev/sdb}
ASDF_VERSION=v0.14.1

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
install -d -m 0755 /data/tenants
install -d -m 0750 -o ubuntu -g ubuntu /data/druzhok

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q git curl build-essential nftables unzip \
  libssl-dev libncurses-dev autoconf m4 libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils \
  python3 python3-venv ffmpeg unattended-upgrades debian-keyring debian-archive-keyring apt-transport-https
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
if [ ! -d /opt/hermes/.git ]; then git clone -q "$HERMES_REPO" /opt/hermes; fi
( cd /opt/hermes && git fetch -q origin && git reset -q --hard origin/main \
  && UV_PROJECT_ENVIRONMENT=/opt/hermes/.venv uv sync --frozen --extra all --extra messaging --extra firecrawl 2>&1 | tail -2 )
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
nft list table inet druzhok >/dev/null 2>&1 && nft delete table inet druzhok
nft -f /etc/nftables.d/druzhok.nft
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/hermes@.service /etc/systemd/system/druzhok.service || true

step "druzhok env"
if [ ! -f /etc/druzhok/druzhok.env ]; then
  cat > /etc/druzhok/druzhok.env <<EOT
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
PHX_HOST=oldey.dev
OPENROUTER_API_KEY=
EOT
  chown ubuntu:ubuntu /etc/druzhok/druzhok.env; chmod 0600 /etc/druzhok/druzhok.env
fi

step "asdf + erlang/elixir for ubuntu (per .tool-versions)"
TV=/home/ubuntu/druzhok/v4/druzhok/.tool-versions
if [ -f "$TV" ]; then
  sudo -u ubuntu -H bash -lc "
    set -e
    [ -d ~/.asdf ] || git clone -q https://github.com/asdf-vm/asdf.git ~/.asdf --branch $ASDF_VERSION
    . ~/.asdf/asdf.sh
    asdf plugin add erlang 2>/dev/null || true
    asdf plugin add elixir 2>/dev/null || true
    cd ~/druzhok/v4/druzhok && KERL_CONFIGURE_OPTIONS='--without-wx --without-javac --without-odbc' asdf install
  "
else
  echo "!! clone the druzhok repo to /home/ubuntu/druzhok first, then re-run for asdf"
fi

echo; echo "bootstrap done. Next: put the Cloudflare token in /etc/caddy/env, then 'systemctl enable --now caddy druzhok'."
