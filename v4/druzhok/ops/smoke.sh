#!/usr/bin/env bash
# smoke.sh <bot-name> [chat_id]
# Verifies a bot end-to-end: unit active, probe healthy (Telegram getMe, proxy
# ping, egress locked) and, if chat_id is given, nudges a real message via the
# manager bot for the operator to confirm in Telegram. Run with sudo.
set -euo pipefail
name=${1:?bot name}; chat=${2:-}
ops=$(cd "$(dirname "$0")" && pwd)
run() { "$ops/druzhok-run.sh" "$1" 2>/dev/null; }

echo "== unit"
st=$(druzhok-ctl status "$name"); echo "$st"; [ "$st" = active ] || { echo "unit not active"; exit 1; }

echo "== probe"
out=$(run "inst = Druzhok.Repo.get_by!(Druzhok.Instance, name: \"$name\"); IO.inspect(Druzhok.HealthMonitor.Probe.run(inst), label: \"probe\")" | grep "probe:")
echo "$out"
echo "$out" | grep -q '{:healthy' || { echo "probe not healthy"; exit 1; }

if [ -n "$chat" ]; then
  echo "== telegram nudge"
  mgr=$(run 'IO.puts(Druzhok.Settings.get("manager_bot_token") || "")' | tail -1)
  if [ -n "$mgr" ]; then
    curl -s "https://api.telegram.org/bot$mgr/sendMessage" -d chat_id="$chat" -d text="smoke($name): now message the bot and confirm it replies" >/dev/null
    echo "nudge sent to chat $chat — confirm the reply manually"
  else
    echo "no manager bot token; skipping nudge"
  fi
fi
echo "SMOKE OK"
