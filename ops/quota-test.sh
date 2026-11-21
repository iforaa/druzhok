#!/usr/bin/env bash
# quota-test.sh — the disk limit's checks on throwaway loop images, by hand,
# as root, on a Linux box with the `quota` package (never in CI, never on /data):
#   sudo bash ops/quota-test.sh
# It repeats what "Checked on the server" in
# docs/superpowers/specs/2026-11-21-bot-disk-limit-design.md found, through this
# tree's druzhok-ctl and tenant-fs pointed at the image: first the window's own
# path (plain ext4 with the bot's files, then e2fsck + tune2fs -O quota +
# usrquota), then enforcement, tenant-fs at the limit, switching off, and the
# setups druzhok-ctl must take as "quotas off". Everything it makes (images,
# mounts, a scratch bot user) is removed on exit. Exit 0 when every check
# passed, 1 when one failed, 2 when the run stopped before the end.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
# The bot user cannot enter the caller's home, and find(1) must be able to
# return to where it started.
cd /
for tool in setquota repquota quotaon quotaoff tune2fs e2fsck mkfs.ext4 findmnt setpriv python3 useradd userdel; do
  command -v "$tool" >/dev/null || { echo "missing: $tool (apt-get install -y quota e2fsprogs)" >&2; exit 1; }
done

OPS=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/quota-test.XXXXXX)
# mktemp makes it 0700, and the bot (no capabilities) must pass through it
# to reach the mount below. Search only: it still cannot list it.
chmod 0711 "$WORK"
IMG=$WORK/img
IMG_NEW=$WORK/img-new
IMG_NOFEATURE=$WORK/img-nofeature
MNT=$WORK/mnt
NAME=qt$$
USER_=bot-$NAME
CTL=$WORK/druzhok-ctl
TFS=$WORK/tenant-fs
DIR=$MNT/tenants/$NAME
FAILED=0
FINISHED=0

cleanup() {
  set +e
  pkill -KILL -U "$USER_" 2>/dev/null
  while mountpoint -q "$MNT"; do umount "$MNT" || break; done
  id -u "$USER_" >/dev/null 2>&1 && userdel "$USER_"
  rm -rf "$WORK"
  if [ "$FINISHED" -eq 0 ]; then
    echo
    echo "STOPPED before the end: the checks after the line above did not run"
    exit 2
  fi
}
trap cleanup EXIT
# Any unguarded command that fails names itself before the run stops.
trap 'echo "ABORT line $LINENO: $BASH_COMMAND" >&2' ERR

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; FAILED=1; }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
# dd's message quotes the file name, so it is matched here, not inside bash -c.
contains() { grep -q "$2" <<<"$1"; }
field() { cut -d'|' -f"$1" <<<"$2"; }

# This tree's helpers, with their tenant root moved onto the image.
sed "s|^TENANTS=/data/tenants$|TENANTS=$MNT/tenants|" "$OPS/druzhok-ctl" > "$CTL"
sed "s|^TENANTS = \"/data/tenants\"$|TENANTS = \"$MNT/tenants\"|" "$OPS/../apps/druzhok/priv/tenant-fs/tenant_fs.py" > "$TFS"
chmod 0755 "$CTL" "$TFS"
grep -q "^TENANTS=$MNT/tenants$" "$CTL" || { echo "could not point druzhok-ctl at the image" >&2; exit 1; }
grep -q "^TENANTS = \"$MNT/tenants\"$" "$TFS" || { echo "could not point tenant-fs at the image" >&2; exit 1; }

# As the bot: its uid and gid, no groups, no capabilities (as hermes@ runs).
as_bot() { setpriv --reuid="$USER_" --regid="$USER_" --clear-groups --inh-caps=-all -- "$@"; }
write_mb() { as_bot dd if=/dev/zero of="$1" bs=1M count="$2" conv=fsync status=none 2>&1; }
# Empties the bot's dir as the bot; a failure is a failed check, not the end of the run.
bot_clean() { as_bot find "$DIR" -mindepth 1 -delete || fail "emptying $DIR as the bot"; }
over_limit() { local out; out=$(write_mb "$DIR/big" 100 || true); as_bot rm -f "$DIR/big" || true; contains "$out" 'Disk quota exceeded'; }
fits() { local ok=0; write_mb "$DIR/big" 100 >/dev/null || ok=1; as_bot rm -f "$DIR/big" || true; return $ok; }
tenant_dirs() { install -d -m 0755 "$MNT/tenants"; install -d -m 0700 -o "$USER_" -g "$USER_" "$DIR"; }

mkdir -m 0755 "$MNT"
useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir "$DIR" "$USER_"

echo "== the window's path: a plain ext4 /data with the bot's files on it"
truncate -s 400M "$IMG"
mkfs.ext4 -q -F "$IMG"
mount -o loop "$IMG" "$MNT"
tenant_dirs
check "the bot can write its dir before the change" write_mb "$DIR/before" 30
for i in $(seq 1 20); do as_bot touch "$DIR/old$i" || fail "touch old$i"; done
umount "$MNT"
rc=0; e2fsck -f -y "$IMG" >/dev/null || rc=$?
check "e2fsck -f is clean (exit $rc)" test "$rc" -le 1
tune2fs -O quota "$IMG" >/dev/null
mount -o loop,usrquota "$IMG" "$MNT"
check "tune2fs lists the quota feature" bash -c "tune2fs -l \"\$(findmnt -n -o SOURCE --target '$MNT')\" | grep -q '^Filesystem features:.*\bquota\b'"
check "the mount shows usrquota" bash -c "findmnt -n -o OPTIONS --target '$MNT' | tr , '\n' | grep -qx usrquota"
line=$("$CTL" disk "$NAME")
check "druzhok-ctl sees quotas on ($line)" test "$line" != -
check "files from before the change are counted: $(field 1 "$line") KB" test "$(field 1 "$line")" -ge $((30 * 1024))
check "and their number: $(field 3 "$line") files" test "$(field 3 "$line")" -ge 21
bot_clean

echo "== a 50 MB, 100-file limit"
"$CTL" quota "$NAME" 50 100
line=$("$CTL" disk "$NAME")
check "disk shows the limits ($line)" bash -c "[ '$(field 2 "$line")' = 51200 ] && [ '$(field 4 "$line")' = 100 ]"
check "disk-all lists the bot" bash -c "'$CTL' disk-all | grep -q '^$NAME|'"

out=$(write_mb "$DIR/big" 100 || true)
check "a write past the limit fails with Disk quota exceeded" contains "$out" 'Disk quota exceeded'
used=$(field 1 "$("$CTL" disk "$NAME")")
check "usage stops at the limit (${used} KB)" test "$used" -le 51200
check "rm works at the limit" as_bot rm -f "$DIR/big"
check "writes resume after it" write_mb "$DIR/small" 10
bot_clean

n=0
while as_bot touch "$DIR/f$n" 2>/dev/null; do n=$((n + 1)); [ $n -lt 200 ] || break; done
check "the file cap stops file number ~100, directories counted (stopped at $n)" bash -c "[ $n -ge 90 ] && [ $n -lt 100 ]"
bot_clean

echo "== tenant-fs writes as the bot, so it is limited too"
req=$(python3 -c "import base64,json,sys; print(json.dumps({'jobs':[{'name':sys.argv[1],'ops':[{'op':'write','path':['tfs-big'],'data':base64.b64encode(b'\0'*(60*1024*1024)).decode()}]}]}))" "$NAME")
answer=$(printf '%s' "$req" | "$TFS") || answer=
echo "     tenant-fs answered: $(cut -c1-200 <<<"$answer")"
# Only the quota's own error counts: a write refused for any other reason
# (permissions, a bad path) proves nothing about the limit.
check "a tenant-fs write past the limit fails with EDQUOT" python3 -c "
import json, sys
job = json.loads(sys.argv[1])['jobs'][0]
sys.exit(0 if job.get('ok') and job['results'][0].get('error') == 'edquot' else 1)" "$answer"
small=$(printf '{"jobs":[{"name":"%s","ops":[{"op":"write","path":["tfs-small"],"data":"aGk="}]}]}' "$NAME" | "$TFS") || small=
check "a small tenant-fs write works" python3 -c "
import json, sys
job = json.loads(sys.argv[1])['jobs'][0]
sys.exit(0 if job.get('ok') and job['results'][0].get('ok') else 1)" "$small"
bot_clean

echo "== root is not limited, and a chowned file is counted"
dd if=/dev/zero of="$DIR/rootfile" bs=1M count=60 status=none
chown "$USER_:$USER_" "$DIR/rootfile"
used=$(field 1 "$("$CTL" disk "$NAME")")
check "the bot is over its limit (${used} KB)" test "$used" -gt 51200
rm -f "$DIR/rootfile"

echo "== limits survive a remount"
umount "$MNT"; mount -o loop,usrquota "$IMG" "$MNT"
line=$("$CTL" disk "$NAME")
check "still 50 MB after remount ($line)" test "$(field 2 "$line")" = 51200
check "and still enforced" over_limit

echo "== quotaoff -u stops enforcement for everyone, live; quotaon -u brings it back"
quotaoff -u "$MNT"
check "not enforced after quotaoff -u" fits
quotaon -u "$MNT"
check "enforced again after quotaon -u" over_limit

echo "== quota off clears, live"
"$CTL" quota "$NAME" off
line=$("$CTL" disk "$NAME")
check "no limit after off ($line)" bash -c "[ '$(field 2 "$line")' = 0 ] && [ '$(field 4 "$line")' = 0 ]"
check "a 100 MB write now works" fits

echo "== a live remount does not turn enforcement off"
"$CTL" quota "$NAME" 50 100
mount -o remount,defaults "$MNT" || true
check "still enforced after remount,defaults" over_limit
check "remount,noquota is refused" bash -c "! mount -o remount,noquota '$MNT' 2>/dev/null"
check "and it is still enforced" over_limit

echo "== a full unmount and a mount without usrquota: not enforced, druzhok-ctl says off"
umount "$MNT"; mount -o loop "$IMG" "$MNT"
check "disk prints - without usrquota" test "$("$CTL" disk "$NAME")" = -
check "disk-all prints - without usrquota" test "$("$CTL" disk-all)" = -
check "quota exits 0 and does nothing" "$CTL" quota "$NAME" 50 100
check "a 100 MB write works without the option" fits
umount "$MNT"

echo "== a new box: mkfs.ext4 -O quota (bootstrap.sh)"
truncate -s 100M "$IMG_NEW"
mkfs.ext4 -q -F -O quota "$IMG_NEW"
mount -o loop,usrquota "$IMG_NEW" "$MNT"
tenant_dirs
check "druzhok-ctl sees quotas on" bash -c "[ \"\$('$CTL' disk $NAME)\" != - ]"
"$CTL" quota "$NAME" 20 100
out=$(write_mb "$DIR/big" 40 || true)
check "and they are enforced" contains "$out" 'Disk quota exceeded'
umount "$MNT"

echo "== usrquota without the feature: quotas off for druzhok-ctl, setquota fails"
truncate -s 200M "$IMG_NOFEATURE"
mkfs.ext4 -q -F "$IMG_NOFEATURE"
mount -o loop,usrquota "$IMG_NOFEATURE" "$MNT"
tenant_dirs
check "the mount does show usrquota" bash -c "findmnt -n -o OPTIONS --target '$MNT' | tr , '\n' | grep -qx usrquota"
check "setquota itself fails there" bash -c "! setquota -u '$USER_' 0 1000 0 0 '$MNT' 2>/dev/null"
check "disk prints - without the feature" test "$("$CTL" disk "$NAME")" = -
check "quota exits 0 without the feature" "$CTL" quota "$NAME" 50 100
check "and nothing is enforced" fits
umount "$MNT"

FINISHED=1
# The verdict below is an exit status, not an unguarded failure.
trap - ERR
echo
if [ "$FAILED" -eq 0 ]; then echo "all checks passed"; else echo "SOME CHECKS FAILED"; fi
exit "$FAILED"
