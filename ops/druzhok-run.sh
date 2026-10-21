#!/usr/bin/env bash
# druzhok-run.sh <elixir expression>
# Run a one-off `mix run` against the prod DB with the same env and file
# capabilities druzhok.service has (tenant dirs are 0700 bot-owned). The
# manager bot is not started: druzhok.service already polls its token.
#   sudo ops/druzhok-run.sh 'IO.inspect(Druzhok.BotManager.start("mybot"))'
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
expr=${1:?elixir expression}
cd "$(dirname "$0")/.."
# shellcheck disable=SC2016
exec setpriv --reuid=ubuntu --regid=ubuntu --init-groups \
  --inh-caps=+dac_override,+dac_read_search,+chown,+fowner \
  --ambient-caps=+dac_override,+dac_read_search,+chown,+fowner \
  env HOME=/home/ubuntu bash -lc '
    set -a; . /etc/druzhok/druzhok.env; set +a
    . ~/.asdf/asdf.sh
    exec mix run --no-start -e "Application.put_env(:druzhok, :manager_bot, false); Application.ensure_all_started(:druzhok); $0"' "$expr"
