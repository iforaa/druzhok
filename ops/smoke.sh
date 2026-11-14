#!/usr/bin/env bash
# smoke.sh <bot-name> [chat_id]
# Verifies a bot end-to-end: unit active, probe healthy (Telegram getMe, proxy
# ping, egress locked) and, if chat_id is given, nudges a real message via the
# manager bot for the operator to confirm in Telegram. Run with sudo.
set -euo pipefail
name=${1:?bot name}; chat=${2:-}
ops=$(cd "$(dirname "$0")" && pwd)
run() { "$ops/druzhok-run.sh" "$1" 2>/dev/null; }

db=$(. /etc/druzhok/druzhok.env; echo "$DATABASE_PATH")
token=$(sqlite3 "$db" "select telegram_token from instances where name='$name'")

# An asleep bot has no process: its unit, nft elements and listener come
# back with the start that wakes it (sleep/wake spec, "Visibility").
asleep=$(sqlite3 "$db" "select active and sleeping from instances where name='$name'")

echo "== unit"
st=$(druzhok-ctl status "$name"); echo "$st"
if [ "$asleep" = 1 ]; then
  echo "asleep (last start $(sqlite3 "$db" "select coalesce(started_at, '?') from instances where name='$name'")); skipping unit, nft and listener checks"
else
  [ "$st" = active ] || { echo "unit not active"; exit 1; }
fi

echo "== telegram getMe"
me=$(curl -s -m 20 "https://api.telegram.org/bot$token/getMe")
echo "$me" | grep -q '"ok":true' || { echo "getMe failed"; exit 1; }
echo "$me" | grep -o '"username":"[^"]*"'

uid=$(id -u "bot-$name")
envf=/etc/druzhok/$name.env
port=$(sed -n 's/^TELEGRAM_WEBHOOK_PORT="\([0-9]\{1,5\}\)"$/\1/p' "$envf" | head -n 1)

echo "== egress locked"
if [ "$asleep" = 1 ]; then
  echo "skipped (asleep)"
else
  nft list set inet druzhok bot_uids | grep -w "$uid" >/dev/null || { echo "uid $uid not in bot_uids: egress is open"; exit 1; }
  echo "uid $uid in bot_uids"
fi

echo "== webhook port isolation"
if [ "$asleep" = 1 ]; then
  echo "skipped (asleep)"
elif [ -n "$port" ]; then
  nft list set inet druzhok bot_webhook | grep "$uid . $port" >/dev/null || { echo "{ $uid . $port } not in bot_webhook"; exit 1; }
  echo "only uid $uid may answer from port $port"
else
  echo "no webhook port (id out of range): webhook mode unavailable"
fi

echo "== telegram delivery"
mode=$(sqlite3 "$db" "select telegram_mode from instances where name='$name'")
info=$(curl -s -m 20 "https://api.telegram.org/bot$token/getWebhookInfo")
hook_url=$(echo "$info" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
echo "mode $mode, webhook url '${hook_url}'"
if [ "$mode" = webhook ]; then
  host=$(. /etc/druzhok/druzhok.env; echo "$PHX_HOST")
  [ "$hook_url" = "https://$host/telegram/webhook/$name" ] || { echo "webhook not registered to druzhok"; exit 1; }
  err_at=$(echo "$info" | sed -n 's/.*"last_error_date":\([0-9]*\).*/\1/p')
  if [ -n "$err_at" ] && [ $(( $(date +%s) - err_at )) -lt 600 ]; then
    echo "Telegram reports a delivery error in the last 10 min: $(echo "$info" | sed -n 's/.*"last_error_message":"\([^"]*\)".*/\1/p')"; exit 1
  fi
  held=$(echo "$info" | sed -n 's/.*"pending_update_count":\([0-9]*\).*/\1/p')
  [ "${held:-0}" -le 5 ] || { echo "Telegram holds $held update(s) it could not hand to druzhok"; exit 1; }
  if [ "$asleep" = 1 ]; then
    # Anything queued is waking the bot; only a day-old row is stuck.
    stale=$(sqlite3 "$db" "select count(*) from telegram_updates u join instances i on i.id = u.instance_id where i.name='$name' and u.acked_at is null and u.received_at < strftime('%Y-%m-%dT%H:%M:%f', 'now', '-1 day')")
    [ "$stale" = 0 ] || { echo "$stale update(s) pending for more than a day"; exit 1; }
    paused=$(sqlite3 "$db" "select coalesce(telegram_relay_pause_reason, '') from instances where name='$name' and telegram_relay_paused_until > strftime('%Y-%m-%dT%H:%M:%S', 'now') and telegram_relay_pause_reason != 'sleeping'")
    [ -z "$paused" ] || { echo "relay paused: $paused"; exit 1; }
    echo "webhook registered to druzhok, nothing stuck in the queue"
  else
    owners=$(ss -ltnHe "sport = :$port" | grep -o 'uid:[0-9]*' | sort -u || true)
    [ "$owners" = "uid:$uid" ] || { echo "listener on $port owned by '${owners:-nobody}', expected uid:$uid"; exit 1; }
    stale=$(sqlite3 "$db" "select count(*) from telegram_updates u join instances i on i.id = u.instance_id where i.name='$name' and u.acked_at is null and u.received_at < strftime('%Y-%m-%dT%H:%M:%f', 'now', '-60 seconds')")
    [ "$stale" = 0 ] || { echo "$stale update(s) pending for more than 60 s"; exit 1; }
    paused=$(sqlite3 "$db" "select coalesce(telegram_relay_pause_reason, '') from instances where name='$name' and telegram_relay_paused_until > strftime('%Y-%m-%dT%H:%M:%S', 'now')")
    [ -z "$paused" ] || { echo "relay paused: $paused"; exit 1; }
    echo "webhook registered, listener owned by the bot, queue drained"
  fi
else
  [ -z "$hook_url" ] || { echo "polling bot still has a webhook registered"; exit 1; }
fi

# Run through the bot's uid, asleep or not: exec neither starts nor wakes it.
# --check imports every private hermes name the script uses, so a hermes update
# that renames one fails here instead of in an owner's save.
echo "== panel save script"
script=/usr/local/lib/druzhok/panel-save.py
cmp -s "$ops/../apps/druzhok/priv/panel-save/save.py" "$script" || { echo "$script is missing or stale: install it (CLAUDE.md, deploy recipe)"; exit 1; }
[ "$(stat -c %U "$script")" = root ] || { echo "$script is not root's"; exit 1; }
check=$(druzhok-ctl exec "$name" /opt/hermes/.venv/bin/python -I "$script" --check || true)
echo "$check"
[ "$check" = '{"ok": true}' ] || { echo "the save script cannot import what it needs from hermes"; exit 1; }

# The bundled docx/xlsx/powerpoint/pdf skills need hermes's documents extras, and
# read_file's scan hints and PDF compression need poppler and ghostscript. Imports
# run in the venv the unit runs, so a canary drop-in on a new install is the one
# tested (druzhok-ctl exec's own PATH is /opt/hermes's).
echo "== document libraries"
venv_bin=$(systemctl show -p ExecStart --value "hermes@$name.service" | sed -n 's|.*path=\([^ ;]*\)/hermes .*|\1|p' | head -1 || true)
venv_bin=${venv_bin:-/opt/hermes/.venv/bin}; echo "python: $venv_bin/python"
druzhok-ctl exec "$name" "$venv_bin/python" -I -c 'import docx, openpyxl, pptx, pypdf, pdfplumber, pypdfium2, reportlab, matplotlib, segno' \
  || { echo "document libraries missing: install hermes with --extra documents --extra documents-pdf --extra druzhok-docs"; exit 1; }
for bin in gs pdftoppm pdftotext; do
  command -v "$bin" >/dev/null || { echo "$bin missing: apt-get install ghostscript poppler-utils"; exit 1; }
done

# The shared converter, from the bot's own uid: the shim on its PATH sends a
# generated .docx to druzhok (known by its socket's uid), the wrapper converts it
# in the sandbox, and the PDF's text must come back, Cyrillic included.
echo "== document conversion"
cmp -s "$ops/soffice-shim" /usr/local/bin/soffice || { echo "/usr/local/bin/soffice is missing or stale: install ops/soffice-shim (CLAUDE.md, deploy recipe)"; exit 1; }
[ "$(readlink /usr/local/bin/libreoffice)" = soffice ] || { echo "/usr/local/bin/libreoffice is not a link to the shim"; exit 1; }
cmp -s "$ops/docs-convert" /usr/local/lib/druzhok/docs-convert || { echo "/usr/local/lib/druzhok/docs-convert is missing or stale"; exit 1; }
[ "$(stat -c %U /usr/local/lib/druzhok/docs-convert)" = root ] || { echo "the docs-convert wrapper is not root's"; exit 1; }
[ -x /usr/lib/libreoffice/program/soffice ] || { echo "LibreOffice missing: apt-get install libreoffice-core-nogui libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui"; exit 1; }
id -u cleo-docs >/dev/null 2>&1 || { echo "no cleo-docs user"; exit 1; }
# In the bot's workspace, not /tmp: druzhok-ctl exec runs without the unit's
# PrivateTmp, so the bot user cannot write the host's /tmp. Made by the bot,
# removed by this script whatever happens.
smoke_dir=/data/tenants/$name/workspace/.smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
trap 'rm -rf "$smoke_dir"' EXIT
conv=$(druzhok-ctl exec "$name" "$venv_bin/python" -I -c '
import docx, os, shutil, subprocess, sys
d = sys.argv[1]
os.mkdir(d, 0o700)
try:
    src = os.path.join(d, "smoke.docx")
    doc = docx.Document(); doc.add_paragraph("Проверка конвертера Дружок"); doc.save(src)
    r = subprocess.run(["soffice", "--headless", "--convert-to", "pdf", "--outdir", d, src], capture_output=True, text=True, timeout=300)
    print(r.stdout.strip(), r.stderr.strip())
    t = subprocess.run(["pdftotext", os.path.join(d, "smoke.pdf"), "-"], capture_output=True, text=True).stdout
    print("TEXT:" + " ".join(t.split()))
finally:
    shutil.rmtree(d, ignore_errors=True)
' "$smoke_dir" || true)
echo "$conv"
echo "$conv" | grep -q "TEXT:Проверка конвертера Дружок" || { echo "document conversion failed"; exit 1; }

# Without ops/patch-mnemosyne.py recall silently drops to keyword-only.
echo "== mnemosyne embeddings allowed on loopback"
/opt/hermes/.venv/bin/python "$ops/patch-mnemosyne.py" --verify /opt/hermes || exit 1

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
