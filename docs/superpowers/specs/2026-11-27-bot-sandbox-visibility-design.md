# Bot sandbox: hide the host and the other bots

Date: 2026-11-27. Status: draft, revised after review rounds 1 and 2. Built so far: the backup symlink guard (section 3, first requirement).

## Why

A bot's owner asked their bot (igorhermes) to look around the server. It could
not read or write another bot's data, and it could not reach the network
beyond Druzhok, DNS and Telegram. But it could read things it has no need for:

- the Druzhok source and build (`/data/druzhok-app`, 0755), `/data/home-ubuntu`;
- the names of all bots: `ls /data/tenants`, file names in `/etc/druzhok`,
  `/sys/fs/cgroup/system.slice/system-hermes.slice/hermes@<bot>.service`,
  `/run/systemd/units`, `/run/systemd/propagate`, `/etc/passwd`, `/etc/group`;
- `/etc/caddy` (domains, the gateway's IP), the `/var/log` listing, the
  helpers in `/usr/local/lib/druzhok` and `/usr/local/sbin/druzhok-ctl`.

A bot runs code a stranger can steer (prompt injection through a web page, a
file, a group chat). The source is a map of the platform's defences and the
names say who the customers are. Neither is access, so this is hardening, not
an incident.

## Goal

From inside a bot (its unit, and every other process that runs as its user):

1. No file of the platform's source, build or helper scripts can be read.
   Two deliberate exceptions, neither holding a secret: the `soffice` shim in
   `/usr/local/bin` (the bot runs it) and `panel-save.py` (it runs as the bot,
   so the bot can read it through `/proc/<pid>/root` while it runs).
2. Other bots' names are gone from the places a bot lands on by looking
   around: `/data`, `/etc/druzhok`, `/etc/systemd`, `/run`, `/var`, cgroups.
   This is tidying, **not a guarantee**: see "Not goals".
3. Nothing the bot does today stops working.

## Not goals (accepted, stated to the owner)

- Hiding that other tenants exist, or their names. The network namespace is
  shared: `/proc/self/net/unix` lists every awake bot's sockets by path
  (`/data/tenants/<bot>/gateway.sock`), so a bot that watches it collects the
  names of the bots that wake; `/proc/self/net/tcp` shows other sockets and
  uids; `/etc/passwd` lists every `bot-*` user; hostname, RAM and disk totals
  stay visible. Closing that needs a network namespace per bot, which is the
  container/gVisor project, not this one. For the same reason there is no
  phase 2 for `/etc/passwd`: hiding names there buys nothing while the socket
  list shows them.
- Hiding hermes's own code: Python reads it to run, and it is open source.
- Replacing `/etc` with a per-bot copy. Two outside reviews proposed it; it is
  the fragile part (certificates, fonts, alternatives, resolver) and a
  container replaces it.
- `ProcSubset=pid`: psutil's `children()` breaks under it and a bot then
  cannot sleep (`apps/druzhok/test/ops/hermes_unit_test.exs`). Measured too:
  it does not hide `/proc/self/net`.

## Measured on prod (2026-11-27, systemd 255.4, transient unit as bot-igorhermes)

With the directives below:

- `/data` holds `opt` and `tenants/igorhermes` only; `/var` holds `tmp`
  (PrivateTmp, writable); `/run` holds `systemd/notify` only.
- `/sys/fs/cgroup` holds the unit's own cgroup only; `memory.max` reads the
  unit's limit.
- No file or directory named after another bot is found outside
  `/etc/passwd`, `/etc/passwd-`, `/etc/group`, `/etc/group-`.
  `/proc/self/mountinfo` names no other bot and not `druzhok-app`.
- `hermes --version` runs; `pwd.getpwuid` works; psutil `children()`,
  `create_time()`, `virtual_memory()` work; a datagram to `$NOTIFY_SOCKET`
  is accepted.
- With `/usr/local/sbin` empty and `/etc/systemd`, `/etc/nftables.d`,
  `/etc/nftables.conf` inaccessible as well (second run), the same checks
  pass. Left readable and naming the platform: `/etc/fstab` and its backup
  (mount options only), the `soffice` shim.
- Before this change a bot could also read `druzhok-backup` and
  `backup-mirror` (bucket names, where the keys are), the firewall rules
  (`/etc/nftables.d/druzhok*.nft`), `druzhok.service`, and one
  `hermes@<bot>.service.d` drop-in dir; a hermes update creates such a dir
  for every bot for hours.
- **DNS fails** when `/run` is empty: `/etc/resolv.conf` is a symlink to
  `/run/systemd/resolve/stub-resolv.conf`. With that one file bound back,
  DNS and TLS to api.telegram.org work.
- **A same-user process outside the sandbox defeats it.** A `sleep` started
  with `setpriv --reuid=bot-igorhermes` in the host's namespace was visible to
  the sandboxed bot, and `ls /proc/<pid>/root/data/tenants` listed all 16
  bots and `/proc/<pid>/root/data/druzhok-app` the source. So every path that
  runs as a bot's uid has to be covered, not only the unit.

## Who runs as a bot's uid

| Path | Today | Change |
|---|---|---|
| `hermes@<bot>.service` | the unit's sandbox | the directives below |
| `druzhok-ctl exec` (`ops/druzhok-ctl`, the `exec)` case; panel saves, hermes CLI calls) | its own copy of the sandbox on `systemd-run` | the same directives, with one exception for `panel-save.py` |
| `druzhok-backup` `stage_db` (`sqlite3` under `setpriv`, nightly, every bot database) | host namespace, dumpable | make it unreachable through `/proc` (below) |
| `tenant-fs` (`apps/druzhok/priv/tenant-fs/tenant_fs.py`) | effective uid the bot's, real uid root | none: the bot fails the ptrace check on a process whose real uid is not its own, so `/proc/<pid>/root` is refused. Verify in the canary. |
| `docs-convert` | user `cleo-docs`, not a bot | none |
| `ops/quota-test.sh` | a test user, run by hand | none |

## Design

### 1. `ops/hermes@.service`

Add, keeping every existing line except `ProtectControlGroups=yes`:

```ini
# The bot sees its own dir and the runtime under /data, nothing else: not the
# other bots' names, not druzhok's source, not ubuntu's home.
TemporaryFileSystem=/data:ro
BindReadOnlyPaths=/data/opt
BindPaths=/data/tenants/%i

# /run and /var hold other units' names, logs, host state. Kept: the socket
# READY=1 and the watchdog go to, and the resolver file /etc/resolv.conf
# points at. PrivateTmp still gives a private /var/tmp.
TemporaryFileSystem=/run:ro /var:ro
BindReadOnlyPaths=/run/systemd/notify /run/systemd/resolve/stub-resolv.conf

# Only its own cgroup (hermes reads memory.max from it to size its cache).
# ProtectControlGroups=yes would win over a tmpfs on the same path in 255.
ProtectControlGroups=no
TemporaryFileSystem=/sys/fs/cgroup:ro
BindReadOnlyPaths=/sys/fs/cgroup/system.slice/system-hermes.slice/%n

# Platform config and helpers.
# Whole dirs, so the next file put there is hidden too: druzhok-ctl,
# druzhok-backup and backup-mirror in sbin; the units, per-bot drop-ins and
# the firewall rules in /etc.
InaccessiblePaths=/etc/druzhok /etc/caddy /etc/systemd -/etc/nftables.d -/etc/nftables.conf
TemporaryFileSystem=/usr/local/sbin:ro
InaccessiblePaths=-/usr/local/lib/druzhok -/opt/druzhok-fetch
InaccessiblePaths=-/boot -/srv -/mnt -/media
```

Notes:

- `EnvironmentFile=/etc/druzhok/%i.env` is read by systemd before the mount
  namespace exists, so hiding `/etc/druzhok` does not affect it.
- `/opt/hermes` is a symlink to `/data/opt/hermes-<ver>`; binding all of
  `/data/opt` keeps the venv, uv's Python and absolute paths working across
  hermes updates with no unit change. It also shows old hermes releases and
  uv's cache, which hold no platform or tenant data.
- `ProtectControlGroups=no` plus a read-only tmpfs and a read-only bind: the
  cgroup files are root-owned and the unit has no delegation, so the bot
  could not write them before either.
- `/usr/local/bin` stays (the `soffice` shim, `uv`).
- stdout/stderr reach the journal through descriptors opened before the
  namespace; hermes does not use `/dev/log`.

### 2. `ops/druzhok-ctl` `exec)`

The same additions on the `systemd-run` line, with these differences:

- `--unit=hermes-exec-<bot>-<random>` is not needed: exec gets the empty
  cgroup tmpfs and no own-cgroup bind (nothing it runs reads cgroup limits).
- `/usr/local/lib/druzhok`: `TemporaryFileSystem=/usr/local/lib/druzhok:ro`
  plus `BindReadOnlyPaths=/usr/local/lib/druzhok/panel-save.py`, because panel
  saves run that script through exec
  (`apps/druzhok/lib/druzhok/panel/editor.ex`, `exec/3`).
- No notify socket bind (not a notify unit); the resolver file is bound.

`panel-save.py` is therefore readable by the bot while an exec runs (goal 1's
exception). The tmpfs still hides `docs-convert` and `tenant-fs`.

The comment there already says "keep the two in step"; a test derived from
the unit file enforces it (section 5).

### 3. `ops/druzhok-backup` `stage_db`

Two separate defects, both reachable because `sqlite3` runs under `setpriv`
as the bot's uid in the host's namespace and is dumpable:

a. **Visibility:** the bot can read the host through `/proc/<pid>/root` for
   the seconds the copy runs.
b. **Root follows the bot's symlink** (found in review, fixed on prod
   2026-11-27 ahead of this spec): through the same path the bot can write
   in its work dir `/data/backup-stage/.w/<uid>` and swap the finished copy
   for a symlink; root's `chown`/`chmod` then followed it, so a bot could turn
   any host file into root:root 0600.

Requirements, each on its own:

- **Root never trusts the work dir** (done): after `mv` into the root-owned
  stage dir, the copy must be a regular file, not a link, with one name
  (`stat -c %h` = 1); otherwise it is removed and `FAILED=1`. `chown -h`.
  This stays whatever runs the copy.
- **The copying process is not reachable through `/proc`:** a root-owned
  helper replaces `setpriv … sqlite3`.
  - Source `apps/druzhok/priv/sqlite-copy/sqlite_copy.py`, installed at
    `/usr/local/lib/druzhok/sqlite-copy` (root 0755), `python3 -I`, standard
    library only. Usage: `sqlite-copy <uid> <gid> <src> <dest>`.
  - As root it clears groups, `setresgid`/`setresuid` to the owner for good,
    sets no-new-privs and `PR_SET_DUMPABLE=0`, and only then opens `<src>`
    (`O_NOFOLLOW`, must be a regular file) and copies with the `sqlite3`
    module's backup API. No `exec` follows, so it stays non-dumpable and the
    bot fails the ptrace check on `/proc/<pid>/root`.
  - **It checks its own drop** before opening anything, as `tenant-fs`'s
    `become()` does: real, effective and saved uid and gid are the owner's,
    no supplementary group, `CapEff` is 0, `prctl` returned 0 and
    `PR_GET_DUMPABLE` reads 0. Any miss: exit non-zero, nothing opened.
  - **Bounded:** CPython's `backup()` retries a locked database without end,
    unlike the CLI. `druzhok-backup` runs the helper under
    `timeout -k 5 60`, and the helper sets `signal.alarm(45)` itself; either
    ends it, the copy counts as failed (`FAILED=1`), and the flock is not
    held by a hung copy.
  - The environment stays empty (`env -i`): the S3 keys never reach it.
  - `druzhok-backup` checks the helper exists and is root's before staging
    anything and dies otherwise; it never falls back to `setpriv`.
- Keeps what the current code guarantees: the copy is made with the owner's
  rights (no root-owned `-wal`/`-shm`; a `*.db` that is a link to a root file
  is not opened as root).

Install, like the other helpers in that dir (none of this exists today for
`druzhok-backup` either, which the review found):

- `ops/bootstrap.sh`: install `sqlite-copy`, `druzhok-backup` and its four
  unit files.
- CLAUDE.md deploy recipe: `sqlite-copy` "every deploy", `druzhok-backup`
  "when it changed", helper first.
- `ops/smoke.sh`: `cmp -s` of the installed helper and of
  `/usr/local/sbin/druzhok-backup` against the tree, both root-owned, and one
  real run, shaped like `stage_db`: a temp work dir owned by the bot (0700,
  the helper has dropped to the bot and could not write into a root-only
  one), the helper copies the bot's `state.db` there, and root then checks
  the result without trusting the dir: a regular file, not a link, one name,
  owned by the bot's uid (which proves the drop), starting with the SQLite
  header (`head -c 16`). Root does not open it with sqlite. Then removed.
  The privilege drop can only be exercised here (root, Linux); the dev-box
  tests cannot.
- CLAUDE.md Development commands: the helper's `python3 -m unittest
  discover -s apps/druzhok/test/sqlite_copy` line, next to the other Python
  suites.

The transient-unit alternative (each copy in `systemd-run` with the unit's
sandbox) was weighed: about 95 transient units a night on one core, and the
work dir would need its own bind. The helper is smaller.

### 4. Housekeeping

Delete `/data/druzhok-app/erl_crash.dump` (2026-11-21, 8.5 MB,
druzhok:druzhok 0640: bots cannot read it, but a crash dump holds process
memory).

### 5. Tests

- `apps/druzhok/test/ops/hermes_unit_test.exs`: the new lines are present;
  `ProtectControlGroups=yes` is absent and the cgroup tmpfs and own-cgroup
  bind are present; the notify socket and the resolver file are bound;
  `ProcSubset` still absent.
- New, **derived from the unit file, not from a list of directives**: parse
  every `key=value` of `[Service]` in `hermes@.service`, splitting a
  multi-path value into one pair per path. Drop only the keys in a short
  ignore list that are not sandboxing (`Type`, `NotifyAccess`, `WatchdogSec`,
  `User`, `Group`, `EnvironmentFile`, `Environment`, `WorkingDirectory`,
  `ExecStart`, `Restart`, `RestartSec`, `TimeoutStartSec`, `KillMode`,
  `CPUWeight`). Parse the `exec)` `systemd-run` call of `ops/druzhok-ctl` the
  same way (each `-p key=value`, values split the same way; `$root` reads as
  `/data/tenants/%i`). Every remaining unit pair must be on the exec line,
  except a named list of pairs: the notify bind, the own-cgroup bind, and
  `InaccessiblePaths=-/usr/local/lib/druzhok` (exec has the tmpfs and the
  `panel-save.py` bind instead, which the test asserts). A directive added
  to the unit alone then fails the test. Two more rules:
  - a directive with an empty value is a pair too (`CapabilityBoundingSet=`
    resets the set; dropping it from exec must fail);
  - the check runs both ways: every sandbox pair on the exec line must be in
    the unit, apart from the named exec-only pairs, and no key appears twice
    on the exec line with different single values (a stale
    `ProtectControlGroups=yes` next to `=no`).
- `apps/druzhok/test/sqlite_copy/test_sqlite_copy.py` (the place the other
  Python helpers' tests live): a WAL database copied while a writer is
  active passes `integrity_check`; a symlink source is refused; a missing
  source exits non-zero; a database held under an exclusive lock makes the
  helper exit non-zero within its alarm.
- `ops/smoke.sh <bot>` (runs on the host as root after every managed restart,
  rollout and hermes update), not `audit.sh`:
  - through `druzhok-ctl exec` (works asleep too): `ls /data/tenants` prints
    only the bot; `/data/druzhok-app`, `/data/home-ubuntu`, `/etc/druzhok`,
    `/etc/systemd/system`, `/etc/nftables.d`, `/var/log`,
    `/run/systemd/units` cannot be listed; `/usr/local/sbin` is empty; a name
    resolves;
  - when the bot is awake **and its running process has the sandbox**, the
    same checks inside the unit itself: `nsenter` into the main pid's mount
    namespace with the bot's uid and gid. Whether it has it is read from the
    process, not from the unit file (`systemctl show` reports the file as
    last loaded, which `daemon-reload` changes under a running bot):
    `/proc/<main pid>/mountinfo` has a tmpfs mounted at `/data`. A process
    without it is reported as "old unit, restart to apply", not a failure,
    so smoke stays meaningful between rollout steps 3 and 5 and after a
    rollback.
  - Fix the comment there that says exec runs without `PrivateTmp` (it sets
    it; the workspace is used because root cannot see exec's private `/tmp`).

## Rollout

Each step keeps the file it replaces, in `/usr/local/lib/druzhok-prev/`
(root 0700), so its rollback is one `install` of that copy.

1. Tests green locally. Rsync the tree to the server; install nothing yet.
2. **Backup** (all bots, no bot restart): install `sqlite-copy`, then the new
   `druzhok-backup`. Run `druzhok-backup db`, then `druzhok-backup nightly`;
   check `FAILED` is not reported, `last-ok` moved, the snapshot holds the
   same number of `*.db` files as the one before, and one restored database
   passes `integrity_check`.
   Rollback: reinstall the previous `druzhok-backup`.
3. **Exec sandbox** (all bots, no bot restart): install the new
   `druzhok-ctl`. Right away: `ops/smoke.sh` on one awake and one sleeping
   bot, a panel open, a file listing and a setting save on each.
   Rollback: reinstall the previous `druzhok-ctl`.
4. **Unit, canary on igorhermes:** a drop-in
   `/etc/systemd/system/hermes@igorhermes.service.d/sandbox.conf` with the
   new directives (`ProtectControlGroups=no` set there; `%i`, `%n` expand
   in drop-ins). `systemd-analyze verify`, `daemon-reload`, restart the bot
   through Druzhok's restart path. Canary checks, below. Leave it a day,
   including one nightly backup and one sleep/wake.
   Rollback: remove the drop-in, `daemon-reload`, restart the bot.
5. **Unit, all bots:** install `hermes@.service`, remove the drop-in,
   `daemon-reload`. Sleeping bots take it at their next wake; a reboot in the
   middle only means every bot starts on the new unit. Restart awake bots one
   at a time, each when idle, `ops/smoke.sh` after each.
   Rollback: reinstall the previous unit, `daemon-reload`, then restart
   **every awake bot** one at a time: a bot that woke or was restarted by
   systemd after the install runs the new unit too, whoever started it.
6. Commit. CLAUDE.md gets the rule as it really is: a process that runs as a
   bot's uid is visible to that bot, and through `/proc/<pid>/root` so is its
   filesystem, so it must be one of: inside the unit's sandbox (the unit,
   `druzhok-ctl exec`); non-dumpable with the uid dropped before it opens
   anything (`sqlite-copy`); or keeping root as its real uid (`tenant-fs`).

No data is touched at any step.

## Canary checks

Run inside the bot's real namespace (ask the bot through Telegram to run the
commands, and `nsenter` into the main pid's mount namespace with its uid; a
plain `sudo -u` does not test the unit).

Works:
- start within `TimeoutStartSec`, `WatchdogTimestamp` advancing for 10 min;
- a chat turn, a web search, a voice message in and out, an image, memory
  write and recall (mnemosyne), a reminder firing, a docx→pdf conversion
  through the `soffice` shim, a site publish, Cyrillic text in a generated
  PDF or image (fonts without `/var/cache/fontconfig`);
- a background job started and cancelled, then the bot goes to sleep and
  wakes on a message;
- panel: open, list files, save a setting (exec path), while awake and asleep;
- `druzhok-ctl stats`, the console's memory figure, the disk quota figure;
- the nightly backup stages all of the bot's databases (`FAILED=0`,
  `last-ok` touched) and a restore of one passes `PRAGMA integrity_check`.

Hidden:
- `ls /data`, `ls /data/tenants`, `ls /var`, `ls /run`, `ls /etc/druzhok`,
  `ls /etc/systemd/system`, `ls /etc/nftables.d`, `ls /usr/local/sbin`
  (empty), `cat /data/druzhok-app/mix.exs`, `ls /usr/local/lib/druzhok`,
  `find / -name '*<another bot>*'`, `grep -rls <another bot> /etc /var /run`
  (only the passwd/group files), `grep -rlsE 'druzhok|hermes' /etc
  /usr/local` (only fstab, the `soffice` shim and `opencode`);
- during a nightly backup, a `tenant-fs` call and a panel save: for each
  same-uid pid the bot can see, `/proc/<pid>/root/data/tenants` shows only
  itself or fails, and `/proc/<pid>/root/data/druzhok-app`,
  `/proc/<pid>/root/etc/druzhok` and `/proc/<pid>/root/var/log` fail
  (`panel-save.py` readable there is the stated exception);
- the bot's own verdict when asked to explore again.

Recorded as still visible: `/proc/self/net/{tcp,unix,arp}` (the unix list
names awake bots), `/etc/passwd`, hostname, `/proc/meminfo`, `df`.

## Risks

1. A missed dependency under `/run` or `/var` (measured: only the resolver
   file). Caught by the canary; rollback is one file.
2. A missed path that runs as a bot's uid: the sandbox is then only as good
   as that path. The table above is from grepping `ops/` and `apps/*/lib`
   for `systemd-run`, `setpriv`, `sudo -u`, `--uid=`; the test in section 5
   keeps `exec` in step. New such code has to follow the rule (CLAUDE.md).
3. `ProtectControlGroups=no` regressing on a systemd upgrade that changes
   mount precedence: the unit test pins the lines, `smoke.sh` checks the
   result on the live host after every restart and update.
4. hermes updates that start reading a new host path: `update-hermes` already
   rolls bots one at a time and runs `smoke.sh`, which now holds the checks.
5. Fontconfig rebuilding its cache per bot on first use (CPU on a 1-core box,
   and cold starts have hit a 10 s plugin timeout before): measure the first
   image/PDF render in the canary.

## Open questions for review

- Is anything else on this host run as a bot's uid, or reachable by a bot,
  that the table misses (timers, cron, the scheduler, hermes's own
  subprocess supervisors, `systemd-run` scopes)?
- Is binding all of `/data/opt` acceptable, or should it be the current
  release plus `uv-python` only (and then how does a hermes update that
  repoints `/opt/hermes` reach running bots)?
- Does anything rely on a bot reading `/run/systemd/resolve/resolv.conf`
  (not the stub), `/var/lib`, or `/etc/caddy`?
