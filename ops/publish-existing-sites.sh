#!/usr/bin/env bash
# publish-existing-sites.sh [--apply] [<bot>...]
# One-off for the move to the gateway's site API: publishes workspace/sites/* of
# every hosting-enabled bot, each as the bot's own uid. Without --apply it only
# reports what would go. Safe to repeat: a publish replaces the site, but the
# gateway allows 20 an hour per account. Run after druzhok and the gateway have
# the site API; remove this script and the .py next to it once it has run.
#   sudo ops/publish-existing-sites.sh
#   sudo ops/publish-existing-sites.sh --apply
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
cd "$(dirname "$0")/.."

apply=()
only=()
for arg in "$@"; do
  case "$arg" in
    --apply) apply=(--apply) ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) only+=("$arg") ;;
  esac
done

# Lines of their own: mix prints other things on this stdout.
listing=$(ops/druzhok-run.sh 'import Ecto.Query; Druzhok.Repo.all(from i in Druzhok.Instance, where: i.website_hosting_enabled == true and i.delete_requested == false, select: i.name) |> Enum.each(&IO.puts("BOT " <> &1))')
mapfile -t bots < <(printf '%s\n' "$listing" | sed -n 's/^BOT //p')

for want in "${only[@]+"${only[@]}"}"; do
  printf '%s\n' "${bots[@]+"${bots[@]}"}" | grep -qxF -- "$want" || { echo "$want: no such bot, or hosting is off" >&2; exit 2; }
done
[ ${#only[@]} -eq 0 ] || bots=("${only[@]}")

src=$(cat ops/publish-existing-sites.py)
failed=0
echo "${#bots[@]} hosting-enabled bot(s)"
for bot in "${bots[@]+"${bots[@]}"}"; do
  echo "$bot:"
  # exec does not start or wake the bot.
  /usr/local/sbin/druzhok-ctl exec "$bot" python3 -I -c "$src" "${apply[@]+"${apply[@]}"}" || failed=1
done
exit "$failed"
