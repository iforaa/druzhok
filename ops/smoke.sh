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

db=$(. /etc/druzhok/druzhok.env; echo "$DATABASE_PATH")
token=$(sqlite3 "$db" "select telegram_token from instances where name='$name'")

echo "== telegram getMe"
me=$(curl -s -m 20 "https://api.telegram.org/bot$token/getMe")
echo "$me" | grep -q '"ok":true' || { echo "getMe failed"; exit 1; }
echo "$me" | grep -o '"username":"[^"]*"'

echo "== egress locked"
uid=$(id -u "bot-$name")
nft list set inet druzhok bot_uids | grep -qw "$uid" || { echo "uid $uid not in bot_uids: egress is open"; exit 1; }
echo "uid $uid in bot_uids"

echo "== page fetch (/v2/scrape via ruoc)"
key=$(run "IO.puts(Druzhok.Repo.get_by!(Druzhok.Instance, name: \"$name\").tenant_key)" | tail -1)
scrape=$(curl -s -m 60 -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"]}' http://127.0.0.1:4000/v2/scrape)
echo "$scrape" | head -c 200; echo
echo "$scrape" | grep -q '"success":true' || { echo "scrape failed"; exit 1; }

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
