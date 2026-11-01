#!/usr/bin/env bash
# host-input-firewall.sh — load ops/nftables-host-input.nft without risking the
# only way into the box. Run as root.
#
#   apply     schedule the rollback, then load the rules (live only, nothing saved)
#   confirm   cancel the rollback and save the rules, so a reboot keeps them
#   rollback  put back what was there before an unconfirmed apply, now
#   remove    drop a confirmed firewall: live table and saved file
#   status    table, saved file, pending rollback, drop counter
#
# The rollback is a systemd timer, so it fires when the SSH session is gone. Rules
# reach /etc/nftables.d only on confirm, so a reboot also undoes an unconfirmed
# apply. Never use `systemctl reload|restart nftables` here: /etc/nftables.conf
# starts with `flush ruleset`, which also empties @bot_uids and so opens bot egress.
set -euo pipefail

FAMILY=inet
TABLE=host_input
AFTER_S=300
RULES=${HOST_INPUT_RULES:-$(cd "$(dirname "$0")" && pwd)/nftables-host-input.nft}
NFT_CONF=${HOST_INPUT_NFT_CONF:-/etc/nftables.conf}
SAVED=${HOST_INPUT_SAVED:-/etc/nftables.d/host-input.nft}
STATE=${HOST_INPUT_STATE:-/run/druzhok-host-input}
UNIT=druzhok-host-input-rollback

die() { echo "host-input-firewall: $*" >&2; exit 1; }

table_exists() { nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1; }

# Without counters' values, so a live table can be compared with itself later.
table_hash() {
  nft -s list table "$FAMILY" "$TABLE" | sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/' | sha256sum | cut -d' ' -f1
}

pending() { systemctl is-active --quiet "$UNIT.timer"; }

cancel_timer() { systemctl stop "$UNIT.timer" "$UNIT.service" 2>/dev/null || true; }

preflight() {
  [ -r "$RULES" ] || die "no rules file: $RULES"
  nft -c -f "$RULES" || die "rules do not parse, nothing changed"
  # Rules allow 22 only; another sshd port would lock everybody out.
  local ports
  ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u) ||
    die "sshd -T failed, cannot tell its port: fix sshd first"
  [ "$ports" = 22 ] || die "sshd must listen on 22 only, got: ${ports:-nothing}"
  # confirm saves there; a directory that is not loaded would lose the firewall at boot.
  grep -qE '^[[:space:]]*include "/etc/nftables\.d/\*\.nft"' "$NFT_CONF" ||
    die "$NFT_CONF does not include /etc/nftables.d/*.nft"
}

apply() {
  pending && die "a rollback is pending: run confirm or rollback first"
  preflight
  mkdir -p "$STATE"
  cp "$RULES" "$STATE/applied.nft"
  # The same atomic header as the rules file, then the table as it stands now.
  {
    echo "table $FAMILY $TABLE"
    echo "delete table $FAMILY $TABLE"
    if table_exists; then nft -s list table "$FAMILY" "$TABLE"; fi
  } > "$STATE/previous.nft"
  nft -c -f "$STATE/previous.nft" || die "cannot build a rollback, nothing changed"

  # The rollback exists before the rules do: no window without one. A timer that
  # failed earlier stays loaded under this name, so clear it first.
  systemctl reset-failed "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
  systemd-run --quiet --unit="$UNIT" --on-active="$AFTER_S" --timer-property=AccuracySec=1s \
    "$(command -v nft)" -f "$STATE/previous.nft" || die "cannot schedule the rollback, nothing changed"

  if ! nft -f "$STATE/applied.nft"; then
    cancel_timer
    die "rules did not load, previous table left in place"
  fi
  table_hash > "$STATE/applied.hash"
  echo "applied. Rolls back in ${AFTER_S} s unless you run: $0 confirm"
  echo "From a NEW ssh session and from outside the box, check ssh and the demo first."
}

confirm() {
  pending || die "no rollback pending: nothing to confirm (it may have fired; see status)"
  cancel_timer
  # The timer may have fired just before it was stopped.
  if ! table_exists || [ "$(table_hash)" != "$(cat "$STATE/applied.hash")" ]; then
    die "the rollback already ran, nothing saved: apply again"
  fi
  # A dot name: the include glob does not match it, and the rename is atomic.
  local tmp
  tmp="$(dirname "$SAVED")/.host-input.tmp"
  install -m 0644 -o root -g root "$STATE/applied.nft" "$tmp"
  # The check below reads the include glob, so the rules must be in place for it.
  if [ -f "$SAVED" ]; then cp -p "$SAVED" "$STATE/saved.prev"; fi
  mv -f "$tmp" "$SAVED"
  # A broken conf fails nftables.service at boot, and bot egress lock with it.
  if ! nft -c -f "$NFT_CONF"; then
    if [ -f "$STATE/saved.prev" ]; then mv -f "$STATE/saved.prev" "$SAVED"; else rm -f "$SAVED"; fi
    die "$NFT_CONF does not parse with the new rules: saved file left as it was, the new table stays live until reboot"
  fi
  rm -rf "$STATE"
  echo "confirmed and saved to $SAVED"
}

rollback() {
  pending || die "no rollback pending (a confirmed firewall is undone with remove)"
  # The timer goes only once the old rules are back: if this load fails, it still fires.
  nft -f "$STATE/previous.nft" || die "could not restore the old rules; the timer is still pending"
  cancel_timer
  rm -rf "$STATE"
  echo "rolled back"
}

remove() {
  pending && die "a rollback is pending: run confirm or rollback first"
  rm -f "$SAVED"
  if table_exists; then nft delete table "$FAMILY" "$TABLE"; fi
  echo "removed"
}

status() {
  if table_exists; then echo "table: loaded"; else echo "table: none"; fi
  if [ -f "$SAVED" ]; then echo "saved: $SAVED"; else echo "saved: no"; fi
  if pending; then
    echo "rollback: pending"
    systemctl list-timers --no-legend "$UNIT.timer" || true
  else
    echo "rollback: none"
  fi
  if table_exists; then
    nft list table "$FAMILY" "$TABLE" | grep -E 'counter packets [0-9]+ bytes [0-9]+ drop' || true
  fi
}

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ $# -eq 1 ] || die "usage: $0 apply|confirm|rollback|remove|status"

case "$1" in
  apply|confirm|rollback|remove)
    exec 9> "$STATE.lock"
    flock -n 9 || die "another run is in progress"
    "$1"
    ;;
  status) status ;;
  *) die "usage: $0 apply|confirm|rollback|remove|status" ;;
esac
