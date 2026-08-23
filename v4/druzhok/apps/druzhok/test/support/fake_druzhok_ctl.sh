#!/usr/bin/env bash
# Records every invocation to $FAKE_CTL_LOG and answers like druzhok-ctl.
log="${FAKE_CTL_LOG:?}"
cmd="$1"; name="$2"; shift 2
stdin=""
case "$cmd" in create|update-env) stdin="$(cat)";; esac
printf '%s\t%s\t%s\t%s\n' "$cmd" "$name" "$*" "$(printf '%s' "$stdin" | base64 | tr -d '\n')" >> "$log"
state="${FAKE_CTL_STATE:-/tmp/fake-ctl-state-$name}"
case "$cmd" in
  create)      echo created > "$state"; exit 0;;
  update-env)  exit 0;;
  start)       echo active > "$state"; exit 0;;
  stop)        echo inactive > "$state"; exit 0;;
  restart)     echo active > "$state"; exit 0;;
  destroy)     rm -f "$state"; exit 0;;
  status)      if [ -f "$state" ]; then cat "$state"; else echo unknown; fi; exit 0;;
  stats)       echo "123456|7890"; exit 0;;
  logs)        echo "line1"; echo "line2"; exit 0;;
  exec)        exec "$@";;
  *)           echo "unknown command $cmd" >&2; exit 2;;
esac
