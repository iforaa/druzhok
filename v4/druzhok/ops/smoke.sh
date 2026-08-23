#!/usr/bin/env bash
# smoke.sh <bot-name> [chat_id]
# Verifies a bot end-to-end: unit active, probe healthy (Telegram getMe, proxy
# ping, egress locked) and, if chat_id is given, nudges a real message via the
# manager bot for the operator to confirm in Telegram.
set -euo pipefail
name=${1:?bot name}; chat=${2:-}
cd "$(dirname "$0")/.."
# shellcheck disable=SC1090
. ~/.asdf/asdf.sh 2>/dev/null || true
export DATABASE_PATH=${DATABASE_PATH:-/data/druzhok/druzhok.db} MIX_ENV=prod DRUZHOK_HOST=systemd LLM_PROXY_HOST=127.0.0.1
export SMOKE_NAME=$name

echo "== unit"
st=$(sudo druzhok-ctl status "$name"); echo "$st"; [ "$st" = active ] || { echo "unit not active"; exit 1; }

echo "== probe"
out=$(mix run --no-start -e '
  Application.ensure_all_started(:druzhok)
  inst = Druzhok.Repo.get_by!(Druzhok.Instance, name: System.get_env("SMOKE_NAME"))
  IO.inspect(Druzhok.HealthMonitor.Probe.run(inst), label: "probe")
' 2>/dev/null | grep "probe:")
echo "$out"
echo "$out" | grep -q '{:healthy' || { echo "probe not healthy"; exit 1; }

if [ -n "$chat" ]; then
  echo "== telegram nudge"
  mgr=$(mix run --no-start -e 'Application.ensure_all_started(:druzhok); IO.puts(Druzhok.Settings.get("manager_bot_token") || "")' 2>/dev/null | tail -1)
  if [ -n "$mgr" ]; then
    curl -s "https://api.telegram.org/bot$mgr/sendMessage" -d chat_id="$chat" -d text="smoke($name): now message the bot and confirm it replies" >/dev/null
    echo "nudge sent to chat $chat — confirm the reply manually"
  else
    echo "no manager bot token; skipping nudge"
  fi
fi
echo "SMOKE OK"
