#!/usr/bin/env bash
# audit.sh — known vulnerabilities in what the host runs. It changes no dependency.
#
#   ops/audit.sh        on a dev machine: mix, hermes, fetch worker, panel, and apt if any
#   ops/audit.sh apt    on the host: pending security updates only, read only. The host has
#                       no dev deps or hermes clone, and must not compile on the demo's CPU.
#   HERMES_DIR=/path    hermes clone with uv.lock (default: <repo>/hermes-agent)
#
# Writes only caches in the user's home: uvx's pip-audit, mix_audit's advisory clone, _build.
# Every section runs, whatever the others found. Exit 0 = nothing found, 1 = findings or a
# section that could not complete. Only apt on a machine without apt is "not applicable".
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HERMES_DIR=${HERMES_DIR:-$ROOT/hermes-agent}
# The extras ops/bootstrap.sh installs: audit what production has.
HERMES_EXTRAS=(--extra all --extra messaging --extra firecrawl --extra mnemosyne)
# mix_audit ignores git's exit status: a failed clone audits against nothing and passes,
# a failed pull against stale data. So check both around it (deps/mix_audit/lib/mix_audit/repo.ex).
ADVISORIES_URL=https://github.com/mirego/elixir-security-advisories.git
ADVISORIES_DIR=$HOME/.local/share/elixir-security-advisories-mirego/packages
failed=0

section() { echo; echo "== $*"; }
incomplete() { echo "could not complete: $*"; failed=1; }
# Runs a check; its exit code counts as a finding.
check() { "$@" || failed=1; }

# pip-audit drops a pin whose marker its own interpreter fails, and hermes's pins say
# python >= 3.14: on an older Python it audits nothing and exits 0.
pip_audit() { uvx --quiet --python 3.14 pip-audit --progress-spinner off "$@"; }

hermes_lock() {
  local reqs
  reqs=$(mktemp) || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$reqs'" RETURN
  # --frozen: never rewrite the fork's lock. Python 3.14 is what production runs.
  uv export --quiet --frozen --no-hashes --no-emit-project --python 3.14 \
    "${HERMES_EXTRAS[@]}" --directory "$HERMES_DIR" -o "$reqs" >/dev/null || return 1
  pip_audit --no-deps --disable-pip -r "$reqs"
}

audit_mix() {
  section "mix deps.audit"
  if ! command -v mix >/dev/null; then incomplete "no mix"; return; fi
  if [ ! -d "$ROOT/deps/mix_audit" ]; then incomplete "no deps/mix_audit: run mix deps.get"; return; fi
  if ! git ls-remote --exit-code "$ADVISORIES_URL" HEAD >/dev/null 2>&1; then
    incomplete "advisory database unreachable"
    return
  fi
  ( cd "$ROOT" && MIX_ENV=dev mix deps.audit ) || failed=1
  if [ -z "$(find "$ADVISORIES_DIR" -name '*.yml' -print -quit 2>/dev/null)" ]; then
    incomplete "advisory database is empty, so the result above means nothing"
  fi
}

audit_python() {
  section "pip-audit: hermes uv.lock"
  if ! command -v uv >/dev/null; then
    incomplete "no uv"
  elif [ ! -f "$HERMES_DIR/uv.lock" ]; then
    incomplete "no $HERMES_DIR/uv.lock (set HERMES_DIR)"
  else
    check hermes_lock
  fi

  section "pip-audit: fetch worker"
  if command -v uv >/dev/null; then
    check pip_audit -r "$ROOT/apps/druzhok/priv/fetch-worker/requirements.txt"
  else
    incomplete "no uv"
  fi
}

audit_npm() {
  section "npm audit: panel"
  if command -v npm >/dev/null; then
    check npm audit --prefix "$ROOT/apps/druzhok_web/assets/app"
  else
    incomplete "no npm"
  fi
}

audit_apt() {
  section "apt: pending security updates"
  local lists=${APT_LISTS_DIR:-/var/lib/apt/lists}
  # macOS has an unrelated /usr/bin/apt, so look for the lists too.
  if ! command -v apt >/dev/null || [ ! -d "$lists" ]; then
    echo "not applicable: no apt here"
    return
  fi
  # Empty or old lists make apt list exit 0 with nothing upgradable.
  if [ -z "$(find "$lists" -maxdepth 1 -name '*_Packages*' -mtime -7 -print -quit 2>/dev/null)" ]; then
    incomplete "apt lists are empty or over 7 days old"
    return
  fi
  # The lists as the daily timer left them: refreshing needs root and is not read only.
  local listing sec
  if ! listing=$(apt list --upgradable 2>/dev/null); then
    incomplete "apt list failed"
    return
  fi
  sec=$(printf '%s\n' "$listing" | grep -- '-security' || true)
  if [ -n "$sec" ]; then
    printf '%s\n' "$sec"
    failed=1
  else
    echo "none"
  fi
}

case "${1:-all}" in
  all) audit_mix; audit_python; audit_npm; audit_apt ;;
  apt) audit_apt ;;
  *) echo "usage: $0 [apt]" >&2; exit 2 ;;
esac

echo
if [ "$failed" -eq 0 ]; then echo "audit: nothing found"; else echo "audit: findings or incomplete sections above"; fi
exit "$failed"
