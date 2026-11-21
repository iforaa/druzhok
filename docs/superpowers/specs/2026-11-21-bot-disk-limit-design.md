# Per-bot disk limit

Date: 2026-11-21. Status: revised after review rounds 1 and 2, ready to build. Repo: druzhok. One migration, two new settings, one
host change (maintenance window).

## Goal

Today nothing limits how much a bot writes. The only guard is `min_free_disk_mb`, which stops new bots from being
created. One runaway bot can fill `/data` (30 GB, shared by every bot, the hermes installs and druzhok itself).

Each bot gets a hard limit of 1 GB and 100,000 files. The owner is warned before the limit, and the operator sees
usage, is told when a bot is full, and can raise one bot.

## Decisions

| Item | Decision |
|---|---|
| Mechanism | ext4 user quota on `/data`. Each bot is the Linux user `bot-<name>` and can write persistently only below `/data/tenants/<name>`, so a user quota is a per-bot limit |
| Size | 1 GB for every bot (owner, 2026-11-21). Setting `bot_disk_mb`, default 1024 |
| File count | 100,000. Setting `bot_disk_files`, default 100000. The largest bot has 31,195 files; `/data` has 1,966,080 inodes |
| One bot needs more | Nullable `instances.disk_mb`, set by the operator only. The file cap grows with it: `bot_disk_files × disk_mb / bot_disk_mb` |
| A full bot's way out | The owner writes to support; the operator is alerted and raises that bot (owner, 2026-11-21). No file delete in the cabinet |
| Soft limit / grace | None. Hard limits only; the warnings are ours, not the kernel's |
| Off switch | `bot_disk_mb=off` clears every bot's limits (see `Settings`) |
| Host without quotas | Limits are not set, usage is unknown, nothing warns. Dev Macs, CI, and prod until the window |
| Temp folder | Not touched. `PrivateTmp=yes` stays, and `ops/hermes@.service` does not change (owner, 2026-11-21; see "Out of scope") |
| Capacity | The limit stops one runaway bot. It is not a capacity plan: 60 bots × 1 GB is more than the disk. `min_free_disk_mb` stays as it is |

## Checked on the server (2026-11-21)

Two runs on a throwaway 400 MB loop image on cleo-demo (kernel 6.8.0-149, e2fsprogs 1.47.0, quota tools 4.06
unpacked without installing), as a uid with no capabilities. `/data` was not touched.

Switching on:
- `tune2fs -O quota` on the unmounted image works, and files that existed before are counted afterwards.
- **The feature alone counts usage but does not enforce limits.** Mounted with plain `defaults`, a user with a 50 MB
  limit wrote 100 MB. Enforcement needs the mount option `usrquota`, or `quotaon -u` after every mount.
- **The mount option without the feature does nothing useful.** The mount succeeds and `/proc/mounts` shows
  `quota,usrquota`, but `setquota` and `repquota` fail (exit 1, "Cannot open quotafile") and nothing is enforced.
- `quotaon -p` prints "user quota is on" whether or not limits are enforced, so it is never the check.
- The feature can be read from a mounted filesystem: `tune2fs -l <device>` lists `quota` under "Filesystem features".

Enforced:
- A write past the limit fails with `Disk quota exceeded`; sqlite reports `disk I/O error`; `rm` works at the limit
  and writes resume after it; the 100-file cap stopped file number 96 (directories count).
- Root is not limited. A file root writes and then chowns to the bot is counted but not blocked, so a bot can end up
  over its limit that way (`druzhok-ctl start` runs `chown -R` on data copied in by hand).
- Limits survive a remount.

Switching off:
- `setquota -u <uid> 0 0 0 0` clears one user's limits, live.
- `quotaoff -u <mount>` stops enforcement for everyone, live; `quotaon -u` brings it back.
- A live remount does **not** stop it: `mount -o remount,defaults` leaves `usrquota` set, and
  `mount -o remount,noquota` is refused (exit 32).
- After a full unmount, mounting without the option is not enforced.

`ops/quota-test.sh` repeats all of this through this tree's `druzhok-ctl` and `tenant-fs`. It passed on cleo-demo on
2026-11-21 (37 checks), including a `tenant-fs` write stopped at the limit with `edquot`. The `quota` package is
installed there since that run; its `quota.service` and `quotarpc.service` are disabled and nothing listens.

## Host

- `ops/bootstrap.sh`: install the `quota` package; make a new `/data` with `mkfs.ext4 -O quota`; write the fstab
  line as `defaults,nofail,usrquota`. A box whose `/data` already exists is not changed by bootstrap: it gets the
  feature in a window (see Rollout). The worker checks what the package enables on install (it ships
  `quota.service` and an rpc daemon) and leaves the rpc daemon off.
- cleo-demo gets the feature and the fstab option once, in the window.

## `ops/druzhok-ctl`

**Quotas are on** when all three hold for the filesystem that has `/data/tenants`: `setquota` is installed, its
options in `/proc/mounts` include `usrquota`, and `tune2fs -l` on its device lists the `quota` feature. One helper
decides it, and every command below uses it. Only this setup is supported. Enforcement switched by hand with
`quotaon -u` or `quotaoff -u` is invisible to the helper and to druzhok, so nobody uses those on `/data`.

- `quota <name> <disk_mb> <files>`: set the user's hard limits. `quota <name> off`: clear them. Quotas off: exit 0,
  nothing done. Quotas on and `setquota` fails: print the error to stderr and exit non-zero.
- `disk <name>` → `<used_kb>|<limit_kb>|<files>|<file_limit>`. A user without a limit has `0` in both limit fields.
  Quotas off: `-`.
- `disk-all` → the same for every `bot-*` user, one `name|…` line each, from one `repquota -u -n -O csv` call.
  Quotas off: one line, `-`. No bot name, like `sync-nft`.
- `destroy`: clear the user's limits before `userdel`. Linux reuses uids, and a new bot would inherit them.

`create` is not changed. It rewrites the bot's env file from stdin, so it must never be the way to set a limit: run
by hand with no stdin it would install an empty env file.

The worker also checks one existing risk and reports it without widening scope: after `destroy` and before `purge`
the files keep the old uid, so a new bot that gets that uid would own them and be charged for them.

## Druzhok

### Settings and the row

- `bot_disk_mb`: a positive integer, or `off`. Unset or a typo is 1024, so a typo cannot remove the limit; only the
  exact word `off` does. `bot_disk_files`: through `positive_int`, default 100000.
- Migration on `instances`: `disk_mb` (integer, null), `disk_warned` (string, null: `nil | "80" | "full"`),
  `disk_operator_alerted_at` (null until the operator was told about the current full episode),
  and what the last check read: `disk_used_kb`, `disk_limit_kb`, `disk_files`, `disk_file_limit` (integers, null)
  and `disk_checked_at`.
- A bot's limit is `disk_mb` or `bot_disk_mb`, with the file cap scaled as in Decisions. With `bot_disk_mb=off`
  every bot's limit is `off`, an override included.

### Applying limits

- `Druzhok.Host` gets `quota/3` and `disk_all/0`. `Host.Systemd` calls `druzhok-ctl`; `Host.Process` does nothing
  and answers "unknown", so dev and tests never call `sudo`.
- `Host.Systemd.prepare` calls `quota` right after `create`, so every start and wake applies the current limit. A
  failed `quota` call is logged as an error and does **not** fail the start: an unlimited bot is better than a bot
  that is down, and the check below reports it.
- `sudo ops/druzhok set <bot> disk_mb=<n>` (empty clears it) applies at once, without a restart.
- `sudo ops/druzhok disk-apply` applies the current limit to every bot that is not being deleted, without starting
  or restarting any. It is how the limits reach sleeping bots after the window, and after a settings change.

### The disk check

`Druzhok.DiskCheck`, a GenServer started in `DruzhokWeb.Application` beside `Druzhok.Cabinet` and
`Druzhok.Lifecycle`, so it runs only in druzhok.service and never in an `ops/druzhok` or `druzhok-run.sh` BEAM.
Every 10 minutes it calls `disk_all/0` once and writes the five `disk_*` readings to each row.

Per bot, `pct` is the higher of size and file-count percentage. A bot with limit 0 has no `pct`.

| State now | Reading | Action | New state |
|---|---|---|---|
| nil | 80 ≤ pct < 98 | 80% message to the owner | `"80"` |
| nil or `"80"` | pct ≥ 98 | full message to the owner, alert to the operator. No 80% message | `"full"` |
| `"full"` | pct < 90 | none; clear `disk_operator_alerted_at` | `"80"` |
| `"80"` | pct < 70 | none | nil |

So a bot that is cleaned from full to 85% and fills again gets the full message again, and a bot that jumps
straight past 98% gets one message, not two. A bot that hovers between 70% and 98% is warned at 80% once.

Sending:
- **Owner**: with the bot's own token, the way `Druzhok.Cabinet` sends «Поддержка ответила»; that does not wake or
  restart the bot. The worker reuses that send path.
- **Operator**: with the superbot's token (`manager_bot_token`) to `operator_telegram_id`. Nothing sends to the
  operator today, so this is a new, small path and the only one this spec adds. The operator has opened the
  superbot; a tenant bot's token cannot reach them. Text: bot name, used and limit, and the `ops/druzhok set`
  line that raises it. If either setting is missing, log an error.
- The owner's message goes first. The state is written once it is settled: sent, refused in a way that will never
  succeed (the owner blocked the bot), or the bot has no owner or no token. That is what Cabinet's notes do. A
  transient failure writes nothing and the next tick retries.
- The operator alert is sent on any tick where the state is `"full"` and `disk_operator_alerted_at` is null, and
  the field is set when the send succeeds. So it survives a druzhok restart, is retried until it gets through, and
  is sent once per full episode.

Two conditions the check reports itself, at most once an hour each, as an error in the log and an alert to the
operator:
- quotas were on and are now off, on a `Host.Systemd` host, while `bot_disk_mb` is not `off` (a reboot or an fstab
  edit lost the mount option). The first time the check sees quotas on it writes the settings row
  `disk_quota_seen=1` (kept by the check, not an operator key); before that row exists this condition is silent,
  so nothing warns between the deploy and the window, or on a box without a data disk;
- quotas are on and a bot has limit 0 while its limit should not be `off`.

### Texts (Russian, final wording in review)

- 80%, by size: «Память бота почти заполнена: {used} из {limit}. Попросите бота удалить ненужные файлы.»
- 80%, by file count: «У бота почти закончилось место под файлы: {files} из {file_limit}. Попросите бота удалить ненужные файлы.»
- Full: «Память бота заполнена, он не может сохранять новое. Напишите в поддержку: Кабинет → Поддержка.»

### Where usage shows

All three read the row, never `druzhok-ctl`, and show nothing when `disk_checked_at` is null.

- Cabinet (bot tab): one line with whichever of the two is higher, «245 МБ из 1 ГБ» or «85 000 файлов из 100 000».
- `ops/druzhok list` gets a disk column and `ops/druzhok show <bot>` both numbers, the limits and the check time. A
  bot with limit 0 while quotas are on shows «без лимита».
- `GET /internal/status`: per bot `disk_used_mb`, `disk_limit_mb`, `disk_pct` (null when unknown), and at the top
  level `disk_quota`: `"on"`, `"off"` or null on a host that has none. The column on the CleoHub console page is
  ruoc-gateway work and is not part of this change.

## What a full bot does

Every write fails, including `state.db` and memory, so the bot may answer with errors or not at all, and it cannot
always clean up by itself. The owner is told by druzhok, not by the bot, so the message does not depend on the bot
working. The way out is the operator raising `disk_mb`.

The worker runs one real bot to its limit on a loop image or test box and writes down, in the PR:
- what its user sees while it is running;
- whether it starts again after a stop at the limit (sleep is on by default, so a full bot will be stopped and
  woken). If hermes cannot start at the limit, say so plainly: the controller's start backoff then applies, updates
  wait, and the operator alert is the only thing that gets the bot back.

## Tests

- `druzhok-ctl`: argument parsing, the "quotas off" path, and that `create` is unchanged, in the existing style.
- Elixir: `bot_disk_mb` parsing (`off`, a typo, unset); limit choice and file-cap scaling; every row of the state
  table, including nil → `"full"` in one step and `"full"` → `"80"` → `"full"`; limit 0 does not divide; the state
  is not written when a send fails; `Host.Process` answers unknown.
- `ops/quota-test.sh`: the loop-image checks from "Checked on the server", plus a `tenant-fs` write at the limit.
  Run by hand on a Linux box, not in CI.

## Rollout

1. Merge and deploy. Nothing changes: quotas are off, no unit file changed, and nothing warns. With the deploy,
   install the tools on cleo-demo (`sudo apt-get install -y quota`) and check that the rpc daemon is not running.
   That needs no downtime, and the window's probe and `disk-apply` depend on it.
2. Window, a few minutes of downtime for all bots (accepted by the owner). The Apple review demo on the same machine
   must stay up: before starting, list what holds `/data` open and confirm the demo is not there. On 2026-11-21 only
   hermes processes, druzhok and `tenant-fs` were.
   1. Fresh backup or provider snapshot of the data disk.
   2. Stop druzhok, then every `hermes@*` unit. Druzhok first, so it does not wake bots.
   3. `umount /data`, `e2fsck -f`, `tune2fs -O quota`, add `usrquota` to fstab, `mount /data`.
   4. Probe with a scratch uid: set a small limit, write past it, expect `Disk quota exceeded`, clear the limit.
   5. Start druzhok, then `sudo ops/druzhok disk-apply`.
   6. `ops/smoke.sh`, then `sudo druzhok-ctl disk-all`: every bot has a limit; the largest (vilya, 555 MB) is
      under it.
3. Turning it off again, without downtime: `sudo ops/druzhok settings set bot_disk_mb=off`, then
   `sudo ops/druzhok disk-apply`, which clears every bot's limits. That is the only supported way: druzhok knows
   about it, so it stops warning. To remove the feature for good, also take `usrquota` out of fstab; it takes effect
   at the next unmount or reboot, since a live remount does not work (see "Checked on the server").

## Out of scope

- The bot's `/tmp`. It is on the system disk (20 GB) through `PrivateTmp=yes`, outside the quota, and deleted when
  the unit stops. Moving it into the tenant dir was dropped: the bot owns that dir and could swap the folder for a
  link to a host path, which systemd would follow. A follow-up, with its own design.
- File delete in the cabinet, a bot that cleans up by itself, plans with different sizes, "buy more space".
- The CleoHub console column (ruoc-gateway).
- Cleaning old caches (vilya's 310 MB `uv` cache), group or project quotas, limits on `/data/opt`.
