# Bot sleep/wake

Status: draft r4, 2026-10-20 (r1–r3 reviewed by revmux `sleep-wake/01-initial`, `02-after-fix`,
`03-controller`). Branch
`sleep-wake`. Block A item 6. Builds on the Telegram webhook relay
(`2026-10-20-telegram-webhook-relay-design.md`).

r3 replaces r2's compare-and-set protocol, where five parties (druzhok.service, `druzhok-run.sh` BEAMs,
the dashboard, the sweep, the relay) each changed a bot's state, with **one controller per bot** that is
the only thing allowed to start, stop, sleep, wake or delete it. Everyone else records what they want.

## Goal

A bot that has had nothing to do for a while is stopped ("asleep"). The next Telegram update for it starts
it again ("wake"), and the update is delivered as soon as it listens. Nobody loses a message, and to the
user a sleeping bot only shows as a slower first reply.

What this buys:

1. **RAM.** A fresh hermes is ~230 MB (`MemoryCurrent` after today's restarts) and grows toward the
   800M/1G per-bot limits with use. Over the last 7 days the six bots had LLM traffic in 2–26 distinct
   hours each (`usage_logs`), so most of them are idle almost all the time. Sleeping is what lets one
   host carry many more bots than the 5 GB `system-hermes.slice` fits awake.
2. **Bots come back by themselves.** `hermes@` units are not enabled (`systemctl is-enabled` →
   disabled), so today nothing starts bots after a reboot. The controller converges every `active` bot to
   running (or asleep), so after a reboot awake bots are started and asleep bots wake on their next update.
3. **One place for lifecycle.** Restart, stop and delete stop racing each other across BEAMs (today
   `{:bot_restart, name}` is a `:global` lock local to one BEAM and `stop/1`/`start/1` take none).

Non-goals: waking for cron (v1 keeps bots that have cron jobs awake, see [Cron](#cron)), sleeping polling
bots, multi-host placement (Block B, though the controller is where it would plug in), cutting hermes
cold-start time.

## Facts this design rests on

Checked on the box and in the hermes 0.22.2 source on 2026-10-20.

- **Telegram keeps pushing to a stopped bot's webhook.** Hermes calls `setWebhook` on connect and never
  calls `deleteWebhook` on disconnect, so updates for a stopped bot land in `telegram_updates` and wait
  (relay spec, 24 h expiry). `drop_pending_on_cold_boot: false` keeps them across the cold boot. The
  registration uses the token the bot last ran with; a token change needs a start to re-register.
- **Hermes listens ~5 s after start, systemd reports ready ~26 s after start.** igorhermes and vilya_fe6f
  boots today: `Starting` → `Webhook server listening` 4.6–5.2 s → `Gateway running` ~6 s → 20 s gap →
  model-context warm → `READY=1` at 22–26 s. The unit is `Type=notify`, so `systemctl start` returns only
  at READY. A hermes that exits before READY fails the start job, and `Restart=always` then cycles the
  unit through `activating` on its own.
- **An idle bot is one process.** Each `hermes@` cgroup holds exactly one pid (`hermes`) at rest. Terminal
  and background processes the agent starts (`tools/process_registry.py`) run as children in that cgroup.
- **Hermes records turns in flight.** `<tenant>/gateway_state.json` carries `active_agents`
  (`_active_work_count()`: running agents + cron runs + API runs), rewritten at every turn boundary, and
  `gateway_state` (`running`, `draining`, ...).
- **Hermes's own scale-to-zero does not apply.** `gateway/scale_to_zero.py` arms only for the Nous-hosted
  relay connector and suspends a Fly machine. Its idle predicate is the reference for the checks below.
- **No bot has cron jobs** (`{"jobs": []}` everywhere). Kanban tables are empty; `/goal` is admin-only.
- **A planned stop drains.** `HERMES_RESTART_DRAIN_TIMEOUT=30` gives a running turn 30 s at SIGTERM. A
  stopping hermes still answers 200 to new updates and drops them, which is why every stop pauses the
  relay first. On shutdown Mnemosyne runs its session-end consolidation.
- **Two kinds of BEAM write the DB.** druzhok.service and one-off `ops/druzhok-run.sh` BEAMs (where
  restarts, `set_mode` and rollouts are run by hand) are not clustered.
- **nft elements are re-added only on start.** `druzhok-ctl start` adds the bot's `bot_uids` and
  `bot_webhook` elements; an nftables reload or reboot empties the sets until the next start.
- **`druzhok-ctl status` hides `deactivating`.** It maps every systemd state other than `active`,
  `activating`, `inactive` and `failed` to `inactive`, so a unit draining for 30 s reads as stopped. This
  change adds `deactivating` → `stopping` (and `Host.status` → `:stopping`).
- **The relay worker is one GenServer per bot that runs each delivery step to completion**, so a
  `GenServer.call` to it is answered only between steps, never during a POST.
- **The start code raises.** `write_workspace_files` and `sync_config` use `File.write!`/`mkdir_p!` into
  the tenant tree, which the bot's own agent can change (an `AGENTS.md` turned into a directory raises
  `eisdir` on every start).
- **Callers that act on results.** The manager bot's `restart_for_images` (manager_bot.ex:556) and delete
  confirmation (manager_bot.ex:627) report the outcome to the owner; `Provisioner.provision` writes
  `SOUL.md` after `create` succeeds; the update-hermes skill reads the printed result of a restart.

## Model

Each instance row carries **what is wanted**, which anyone may write, and **what the controller did**,
which only the controller writes.

| column | written by | meaning |
|---|---|---|
| `active` (existing) | anyone | the bot should run (awake or asleep) |
| `start_seq` (int, 0) | anyone | bumped to ask for a fresh start with the current config and env |
| `delete_requested` (bool) | anyone | delete the bot (stop, destroy, wipe, release token, drop the row) |
| `sleep_enabled` (bool, false) | anyone | per-bot opt-in |
| `sleeping` (bool, false) | controller | the controller stopped this active bot because it was idle |
| `applied_seq` (int, 0) | controller | `start_seq` as of the last successful start |
| `failed_seq` (int, 0) | controller | `start_seq` as read by the last failed start |
| `started_at`, `started_mode` | controller | when the last start began, and the `telegram_mode` it used |
| `woke_at` | controller | when the controller last began a wake (relay backoff hint) |
| `start_error`, `start_failed_at`, `start_failures` | controller | last failed start, for backoff and display |

Global `Settings` key `sleep_idle_minutes` (default 30) is the idle window. The migration sets
`start_seq = applied_seq = failed_seq = 0` and `started_mode = telegram_mode` for every row (every prod
bot was last started in its current mode during the relay rollout); nothing copies `start_seq` into
`applied_seq` later, so a request made before the controller's first pass is carried out normally.

The public API becomes requests:

- `BotManager.start(name)` and `restart(name)`: `SET active = true, start_seq = start_seq + 1`. Start and
  restart mean the same thing ("run it, freshly, with what is in the row now"); a Start on a running bot
  restarts it, as dashboard Start is only offered for a bot that is not running.
- `BotManager.stop(name)`: `SET active = false`.
- `BotManager.delete(name)`: `SET active = false, delete_requested = true`. Every delete step is
  idempotent already (`druzhok-ctl destroy` skips a missing user, `TokenPool.release` is an update, a
  second ruoc suspend only logs a warning).
- `BotManager.create/2`: inserts the row as today but with `active = false`, and returns
  `{:ok, %{name:, model:}}` as soon as the row exists, whatever happens to the first start. Its callers
  then call `start(name)`: the provisioner after it has written `SOUL.md` (so the first start already
  has it, which today's code does not guarantee), the dashboard right away. A slow or failed first start
  is the controller's to retry and show, never a creation error (which today would make the owner retry
  after the invite code is spent).
- `Webhook.set_mode/3`, settings saves and token changes are unchanged. Settings and token saves call
  `restart`, which now bumps `start_seq`. `set_mode`'s only caller, `mix druzhok.telegram_mode`, tells the
  operator to restart; if that is forgotten, `started_mode` keeps the bot awake ([Falling
  asleep](#falling-asleep), check 1) and rule 5 wakes an asleep one.

Each is one update, then `Lifecycle.poke(id)` (in druzhok.service it wakes the controller at once; from
another BEAM it is a no-op and the controller sees the row within its 2 s poll).

| call | without `wait` | with `wait: true` (polls the row, up to 120 s) |
|---|---|---|
| `start`, `restart` | `{:ok, name}` once recorded, `{:error, :not_found}` | `{:ok, name}` when `applied_seq >= my_seq`; `{:error, reason}` when `failed_seq >= my_seq` (a failure of an older seq is not mine); `{:error, :timeout}` |
| `stop` | `:ok` | `:ok` once the unit is inactive; `{:error, :timeout}` |
| `delete` | `:ok` | `:ok` once the row is gone; `{:error, :timeout}` |

`{:error, :timeout}` carries no claim about why; the request stays in the row and is carried out whenever
the controller gets to it (also after druzhok.service comes back).

Callers that wait: `druzhok-run.sh` users (the update-hermes skill's per-bot restart, manual restarts), the
manager bot's `restart_for_images` and delete confirmation (both already run in a Task and report the
result to the owner). Callers that fire and forget, as today: dashboard Start/Stop/Restart/Delete, settings
tab saves. The manager bot's bot count and menu also skip `delete_requested` rows.

**`druzhok-ctl` is no longer a lasting control.** `druzhok-ctl stop <bot>` on an `active` bot is undone
by rule 6 within ~30 s. A lasting stop (and the host-move rule "stop a bot on the old host before
starting it elsewhere") goes through `BotManager.stop`; `druzhok-ctl stop` stays for emergencies while
druzhok.service itself is down.

## Controller

`Druzhok.Lifecycle` runs in druzhok.service only (started where the relay is, gated on
`Phoenix.Endpoint.server?`; tests start it explicitly). A `Registry` and `DynamicSupervisor` hold one
`Lifecycle.Bot` GenServer per instance row; a scanner every 2 s starts one for any row without it.

A `Lifecycle.Bot` is the only code that calls `Host.start`, `Host.stop`, `Host.destroy` or writes the
controller columns for its bot, and it does one action at a time. It re-reads its row on every poke and
every 2 s, reads the unit state (`Host.status`) every 30 s and after each of its own actions, runs the idle
checks once a minute, and on each pass takes the **first** rule that applies:

1. **Row gone** → exit.
2. **The unit is `stopping`** → wait. (Whoever began the stop, possibly a controller that died, systemd
   finishes it; nothing may start, resume or deliver into a draining hermes.)
3. **`delete_requested`** → if the unit is not inactive: [stop it](#stopping). Then `Host.destroy`, wipe
   the data dir, release the token, suspend the ruoc account, delete the row (today's `delete/1` body),
   exit.
4. **`!active`** → if the unit is not inactive: [stop it](#stopping). Set `sleeping = false`. Nothing else
   until `active` comes back.
5. **`active && sleeping`** → stay asleep unless a reason to wake holds:
   - an update is pending for it (`Inbox.pending_count > 0`),
   - `start_seq > applied_seq` (someone asked for a start or restart),
   - `!sleep_enabled`, or `telegram_mode != "webhook"`, or `telegram_mode != started_mode`,
   - the unit is active or activating (someone ran `druzhok-ctl start` by hand): just set
     `sleeping = false` and go on to rule 6 next pass.

   To wake: set `woke_at = now`, `sleeping = false`, then the [start action](#start-action).
6. **`active && !sleeping`** → in order:
   - the unit is activating → wait (systemd's `TimeoutStartSec=300` bounds it). A request that arrives
     meanwhile is handled once the unit settles, by the next bullet;
   - the unit is inactive or failed, or `start_seq > applied_seq` → the [start action](#start-action),
     [stopping](#stopping) first if the unit is active (a restart);
   - the bot is [idle](#falling-asleep) → the [sleep action](#falling-asleep);
   - otherwise nothing, except that a `:stopping` or `:sleeping` pause left by an interrupted action is
     cleared here (`resume_if`), since the unit is now seen up and settled.

Every action runs inside `try/rescue` (and `catch :exit`). An exception in the start action is recorded
as a start failure ([below](#start-action)); in any other action it is logged and the pass ends, the next
pass re-observing from scratch. The controller itself therefore does not crash on a bad tenant tree.
`Lifecycle.Bot` children are `restart: :transient` under a supervisor with the default intensity; the
2 s scanner recreates one that did exit abnormally, at most once per scan.

### Stopping

Every stop, for any rule, is the same three steps:

1. `Webhook.pause(id, :stopping)` (or `:sleeping` for the sleep action).
2. `Relay.quiesce(id)`: a `GenServer.call` to the bot's relay worker, which is answered only between
   delivery steps, after which the worker's next step sees the pause. When it returns, no POST is in flight
   and none will start. (No worker running → nothing to wait for.)
3. `Host.stop`.

### Start action

1. Re-read the row. If `!active` or `delete_requested` now, stop here (the next pass applies rule 3 or 4).
   Record `started_at = now`, `started_mode = telegram_mode`, and remember `seq = start_seq`.
2. If the unit is not inactive (failed included), [stop it](#stopping) first. This makes Restart work in
   dev, where `Host.Process.start` is a no-op while a crashed bot's wrapper is still registered.
3. Run the extracted start body: workspace files, `sync_config`, `Host.start` (which runs `druzhok-ctl
   start` and re-adds the nft elements). Unlike today's `do_start` it writes **no** desired-state column
   (`active` is not set back to true, so a Stop made meanwhile wins).
4. Success (`Host.start` returned `:ok` and the unit now reads active): `applied_seq = seq`, clear
   `start_error`, `start_failures = 0`. Clear any pause except `wrong_owner`
   (`Webhook.resume_except(id, :wrong_owner)`): a restart is how an operator fixes what a 403/404
   `rejected_config` pause reports, as the relay worker's moduledoc promises, while a foreign process on
   the port is not fixed by a restart. `Relay.notify(id)`.
5. Failure (an error, an exception, or the unit not active afterwards): `failed_seq = seq`,
   `start_error = reason`, `start_failed_at = now`, `start_failures += 1`; log an error. Then
   [stop the unit](#stopping), so systemd's `Restart=always` does not cycle a hermes that dies before
   READY every 5 s behind the controller's back. The next attempt waits 10 s, 1 min, 5 min, then every
   15 min from `start_failed_at`, unless `start_seq > failed_seq` (a request made after the failure), which
   is tried at once. Updates keep waiting under the 24 h expiry.

`resume_if(id, reason)` and `resume_except(id, reason)` are new in `Webhook`: one conditional update each
on `telegram_relay_pause_reason`.

## Falling asleep

A bot awake under rule 6 is idle when all of these hold:

1. `sleep_enabled`, `telegram_mode == "webhook"`, `started_mode == "webhook"` (a mode switch without a
   restart never puts a still-polling bot to sleep), `start_seq == applied_seq`, and the relay is not
   paused.
2. `started_at` is older than the idle window. Bots running at deploy have `started_at` nil; the
   controller's first pass sets it to now for a bot whose unit is active, and nil never counts as old.
3. No `telegram_updates` row for it with `received_at` inside the window, and none pending.
4. No `usage_logs` row for it inside the window. Every LLM, search, scrape, image and embedding call goes
   through the proxy, so this covers work that Telegram does not show.
5. `gateway_state.json`: `gateway_state == "running"` and `active_agents == 0`. Unreadable or missing →
   not idle (fail awake, as hermes's own predicate does).
6. The unit is `active` and its cgroup holds exactly one process (`druzhok-ctl procs <bot>`, a new
   subcommand printing the count of `cgroup.procs`).
7. No enabled job in `cron/jobs.json`. Unreadable → not idle.

The sleep action:

1. `Webhook.pause(id, :sleeping)` and `Relay.quiesce(id)` ([Stopping](#stopping) steps 1–2). New
   updates now queue, and no delivery is in flight.
2. Re-read the row and re-run checks 1–7, where check 1 accepts the `:sleeping` pause it just set and
   rejects any other. Not idle any more (including an update delivered just before the quiesce) →
   `resume_if(id, :sleeping)`, `Relay.notify`, done.
3. `Host.stop`. The 30 s drain covers a turn that slipped in before the pause.
4. `sleeping = true`, `resume_if(id, :sleeping)`, `Relay.notify`. If updates queued during steps 1–3,
   rule 5 wakes the bot on the next pass (the relay also pokes it, below).

## Relay changes

The worker delivers only to a bot with `active && !sleeping`. For any other row state it holds the queue
(polling as for a pause) and, if the bot is `active && sleeping`, casts `Lifecycle.poke(id)` so the wake
starts at once rather than on the controller's next poll. While `woke_at` is less than 60 s old the retry
backoff is capped at 1 s, so the first update is delivered the moment the listener is up (~5 s), not at
READY (~26 s). Holding rows for `!active` means a Stop takes effect for delivery immediately, before the
controller has stopped the unit. The worker never calls the controller synchronously (poke is a cast), so
the controller's `quiesce` call cannot deadlock.

### Typing indicator

When the controller begins a wake because of a pending update, druzhok sends
`sendChatAction(chat_id, "typing")` with the bot's own token for the chat of the oldest pending update
(message, edited message or callback query; other update types have no chat), and repeats it every 4 s
until that row is acked or 60 s pass. Druzhok, not the bot, has internet, so this needs no egress change.
A failed call is logged at debug and ignored.

### Wake latency

From update to delivery ≈ 5–7 s (listener up) plus druzhok's start overhead (`sync_config`, `chown -R` of
the tenant tree, 0.1–1 s) and up to 2 s of controller poll if the poke is lost. Rollout step 2 measures
whether a turn delivered before READY waits for the 20 s model warm-up; if it does, the first reply after a
wake is ~25 s late and finding that gap moves from follow-up to blocker.

## Crashes and restarts of druzhok

The controller keeps no state that matters outside the row and the unit, so a druzhok restart at any point
is resolved by the next pass of the rules:

| interrupted during | row and unit afterwards | next pass |
|---|---|---|
| any `Host.stop` (sleep, stop, restart, delete) | pause set, unit `stopping` | rule 2 waits; the pause is not touched while the unit drains, so nothing is delivered into it |
| sleep, before `Host.stop` | `!sleeping`, unit active, `:sleeping` pause | rule 6's last bullet clears the pause; bot stays awake |
| sleep, after `Host.stop`, before `sleeping = true` | `!sleeping`, unit inactive, `:sleeping` pause | rule 6 starts it (the start clears the pause): one extra start, no stuck bot |
| a requested start, during `Host.start` | `!sleeping`, unit activating or active, `applied_seq < start_seq` | rule 6 waits while activating, then starts again because `start_seq > applied_seq`: one extra restart |
| a wake (no request), during `Host.start` | `!sleeping`, unit activating or active, seqs equal, `started_at` fresh (written before `Host.start`) | rule 6 waits while activating, then nothing; the bot is awake and the update that woke it keeps it awake for a window |
| stop | `!active`, unit active or inactive | rule 4 stops it again (idempotent) |
| delete, part way | `delete_requested`, some of the steps done | rule 3 re-runs every step; each is idempotent (`druzhok-ctl destroy` and `rm -rf` of a missing path succeed, `TokenPool.release` of a released token is a no-op) |

A druzhok deploy restarts druzhok.service, not the bots, so awake bots keep running through it.

## States shown

| `active` | `sleeping` | unit | dashboard / manager bot |
|---|---|---|---|
| true | false | active | running |
| true | false | activating | starting (waking, if `woke_at` is recent) |
| true | false | inactive / failed | down: retrying (with `start_error` and next attempt) |
| true | true | inactive | 💤 sleeping / `💤 спит` |
| true | true | active / activating | starting (rule 5 clears `sleeping` on the next pass) |
| any | any | stopping | stopping |
| false | any | active / activating | stopping |
| false | false | inactive / failed | stopped |
| any (`delete_requested`) | any | any | deleting |

`false | true` only exists between a Stop and the controller's next pass (rule 4 clears it). Whenever
`start_error` is set, the card shows it and the next attempt time, whatever the row above.

## Cron

A bot with any enabled job in `cron/jobs.json` is never idle (check 7), so cron works exactly as today. A
job is created only during a turn, so an asleep bot cannot gain one. v2, when a bot uses cron: rule 5 also
wakes ~2 min before the earliest `next_run_at`. Not built now because no bot has a job and hermes's
catch-up rules for a job overdue at boot would need their own testing.

## Visibility

- Dashboard: the states above, a per-bot "Sleep when idle" toggle in the settings tab next to "Telegram
  delivery" (disabled with a hint for a polling bot), and `started_at`, `start_error` and next attempt in
  the delivery card. Start/Stop/Restart buttons are unchanged and now just record the request.
- Manager bot: the owner's bot list shows `💤 спит` for an asleep bot.
- `ops/smoke.sh` on an asleep bot prints `asleep since <ts>`, runs the checks that need no process
  (webhook registered to druzhok, Telegram's `pending_update_count`, no row older than 24 h, no pause) and
  skips the unit, nft and listener-owner checks: a stopped bot has no egress or port to guard, and its
  elements come back on start. It exits 0 if those pass.
- Logs, all from the controller: `[life] <bot>: asleep after <n> min idle (rss <mb> MB)`,
  `[life] <bot>: waking (update <id> | restart | mode)`, `[life] <bot>: started in <s> s`,
  `[life] <bot>: start failed (<n>): <reason>, next try in <t>`, `[life] <bot>: stopped`, `deleted`.

## Rollout

1. Deploy with every bot `sleep_enabled = false`. The controller takes over lifecycle; since every bot is
   `active` and running with both seqs at 0, its first pass only fills `started_at`. Check: no
   bot restarted (`systemctl show -p ActiveEnterTimestamp`), dashboard Start/Stop/Restart work on
   igorhermes, `sudo ops/druzhok-run.sh 'BotManager.restart("igorhermes", wait: true)'` returns `{:ok, _}`.
   Rollback here is the previous druzhok build; the new columns are inert for it.
2. Measure the pre-READY turn on igorhermes ([Wake latency](#wake-latency)).
3. Enable igorhermes with `sleep_idle_minutes` temporarily at 2. Test: falls asleep; a DM wakes it and is
   delivered before READY; two messages sent while asleep are both answered in order; a voice note wakes
   it; a message sent during the sleep action is answered; Stop on an asleep bot keeps it down through a
   later message; Stop during a wake leaves it stopped; Stop then Start during a wake leaves it running;
   restart on an asleep bot wakes it; a settings save during a wake is applied after it;
   `systemctl restart druzhok` during a sleep and during a wake ends with the bot awake or asleep and
   consistent; smoke passes asleep and awake. Then back to 30.
4. Enable the other bots one at a time.

## Rollback

Sleep only: `sleep_enabled = false` for the bot (rule 5 then wakes it). All bots: the same in one query.
The controller itself: the previous druzhok build, after waking every bot (`sleep_enabled = false`,
wait for rule 5), since the old code does not know `sleeping`.

## Risks

- **A background job that neither calls the proxy nor shows as a process** (an `asyncio` timer inside
  hermes that posts later). Check 5 only covers turns. Accepted for v1: tenants have no scheduling tool
  other than cron, which check 7 covers.
- **The controller is new infrastructure for every bot**, not just sleeping ones. Rollout step 1 runs it
  with sleep off first, and its first pass changes no running bot.
- **Starting active bots that are down is new behaviour.** A bot that crashes at every start is retried
  with backoff (10 s, 1 min, 5 min, then 15 min) and shown as down with its error; the controller stops
  the unit after each failure so systemd's `Restart=always` does not retry it every 5 s in between. Stop
  ends the retries. A hermes that crashes *after* READY is still restarted by systemd, as today.
- **Wake storms.** A group bot that observes every message wakes on each one. That bot is not idle, and
  the idle window keeps it awake; it costs at most one start per window.
- **Session-end consolidation on every sleep**: an embeddings call per sleep, priced at 0 in ruoc today.
- **First reply after a wake is slower**: 5–7 s best case, ~25 s if turns wait for READY. The typing
  indicator covers the wait. A bot whose owner minds stays opted out.
- **Requests from other BEAMs take up to 2 s to be seen.** Acceptable for manual operations.

## Alternatives considered

- **r2: compare-and-set on a `power` column, transitions owned by whoever won the CAS.** Round 02 found
  nine interleavings it got wrong (a Stop then Start during a transition, a Stop skipping the pause, a
  cooldown dropping a restart, a crash after the final CAS, a delete racing a wake). Each fix added a case;
  a single writer removes the class.
- **Hermes's native scale-to-zero.** Built for the Nous relay connector and Fly machine suspend; needs
  relay-only messaging and a wake URL, and hermes would stop itself outside druzhok's control.
- **Freezing instead of stopping** (`systemctl freeze`). Wakes in milliseconds, but a frozen process keeps
  its RAM, which is the point of sleeping.
- **Clustering the BEAMs so `:global` spans them.** Fixes the lock but keeps many writers, and every
  one-off `druzhok-run.sh` would need a cookie and a node name.

## Tests

- Rules, one test each, with a stub `Host` recording calls: delete (all steps, idempotent on re-run); stop
  pauses before `Host.stop`; `start_seq` bump starts and records `applied_seq`; a request during a start
  gets a second start; a down active bot is started with backoff, and a new request skips the wait once.
- Sleep: each of checks 1–7 blocks it (fixtures for `gateway_state.json`, `jobs.json`, a stub for
  `procs`, rows in `telegram_updates` and `usage_logs`); the re-check accepts the `:sleeping` pause and
  rejects `wrong_owner`; a row arriving between pause and re-check aborts; `started_mode == "polling"`
  blocks.
- Wake: each reason in rule 5 wakes; Stop then Start during a wake ends running; Stop during a wake ends
  stopped; a token change (restart) on an asleep bot starts it.
- Crash table: each row, by killing the controller at that step and starting a new one.
- Requests: `wait: true` returns on completion, on a recorded failure, and times out without a controller.
- Relay worker: holds rows for `!active` and for `sleeping`, pokes the controller for `sleeping`, caps
  backoff at 1 s after `woke_at`.
- Typing indicator: sent for a message update, not for an update without a chat; stops at ack.
- `ops/druzhok_ctl_test`: `procs` prints the cgroup count, refuses an unknown bot.
- smoke: an asleep bot passes; the skipped checks are named in the output.
- Existing `BotManager` and relay tests move to the request API (`wait: true` in tests).
- r4 additions: the unit `stopping` holds every rule and keeps the pause; `quiesce` waits out an in-flight
  POST; an exception in the start body (`write_workspace_files` raising) is a recorded failure with
  backoff and the controller survives; a failure of seq N does not fail a waiter for N+1, and a request
  after a failure skips the backoff; a failed start stops the unit; a Stop during a restart's drain is
  not overwritten; a request made before the first pass after deploy is carried out; the start clears
  `rejected_config` and keeps `wrong_owner`; `create` returns once the row exists and the provisioner's
  `start` follows `SOUL.md`; the manager bot's image restart and delete report the real outcome and the
  menu skips `delete_requested` rows; dev `Host.Process`: restart of a crashed bot respawns it.

## Docs this change updates

- `CLAUDE.md`: the critical rule on wiping `/data/tenants/<name>` (only the lifecycle controller, carrying
  out `BotManager.delete/1`'s request, may); the Telegram delivery bullet (stop/start now hold and release
  the relay through the controller); a lifecycle bullet (requests vs controller, `druzhok-ctl stop` is
  undone for an active bot, `wait: true` for `druzhok-run.sh`).
- `~/.claude/skills/update-hermes/SKILL.md`: per-bot restarts pass `wait: true` and check for `{:ok, _}`;
  a sleeping bot is woken by the restart and moves to the new version then.
- `apps/druzhok/lib/druzhok/telegram/relay/worker.ex` moduledoc: what a restart lifts.

## Follow-ups (not in this change)

- Cron wake (v2 above).
- Find the 20 s between `Gateway running` and READY (a blocker if rollout step 2 shows turns wait for it).
- Side finding: one-off `druzhok-run.sh` BEAMs start their own `ManagerBot` poller, which fights the
  service's (`409 Conflict: terminated by other getUpdates request` in the druzhok journal during every
  run). The one-off BEAM should not start `ManagerBot`.
