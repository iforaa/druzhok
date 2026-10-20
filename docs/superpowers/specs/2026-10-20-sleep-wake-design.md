# Bot sleep/wake

Status: draft r2, 2026-10-20 (r1 reviewed by revmux `sleep-wake/01-initial`). Branch `sleep-wake`. Block A
item 6. Builds on the Telegram webhook relay (`2026-10-20-telegram-webhook-relay-design.md`).

## Goal

A bot that has had nothing to do for a while is stopped ("asleep"). The next Telegram update for it starts
it again ("wake"), and the update is delivered as soon as it listens. Nobody loses a message, and to the
user a sleeping bot only shows as a slower first reply.

What this buys:

1. **RAM.** A fresh hermes is ~230 MB (`MemoryCurrent` after today's restarts) and grows toward the
   800M/1G per-bot limits with use. Over the last 7 days the six bots had LLM traffic in 2–26 distinct
   hours each (`usage_logs`), so most of them are idle almost all the time. Sleeping is what lets one
   host carry many more bots than the 5 GB `system-hermes.slice` fits awake.
2. **Sleeping bots survive a reboot.** `hermes@` units are not enabled (`systemctl is-enabled` →
   disabled), so nothing starts bots after the box reboots. A bot that was asleep at the reboot wakes on
   its next update like any other time. Bots that were awake are not recovered by this change (see
   [Reboot](#reboot) and the follow-ups).

Non-goals: waking for cron (v1 keeps bots that have cron jobs awake, see [Cron](#cron)), sleeping polling
bots, starting awake bots after a reboot, multi-host placement (Block B), cutting hermes cold-start time.

## Facts this design rests on

Checked on the box and in the hermes 0.22.2 source on 2026-10-20.

- **Telegram keeps pushing to a stopped bot's webhook.** Hermes calls `setWebhook` on connect and never
  calls `deleteWebhook` on disconnect, so updates for a stopped bot land in `telegram_updates` and wait
  (relay spec, 24 h expiry). `drop_pending_on_cold_boot: false` keeps them across the cold boot. The
  registration is made with the token the bot ran with last; a token change needs a start to re-register.
- **Hermes listens ~5 s after start, systemd reports ready ~26 s after start.** igorhermes and vilya_fe6f
  boots today: `Starting` → `Webhook server listening` 4.6–5.2 s → `Gateway running` ~6 s → 20 s gap →
  model-context warm → `READY=1` at 22–26 s. The unit is `Type=notify`, so `systemctl start`, and with it
  `BotManager.start/1`, returns only at READY. A hermes that exits before READY fails the start job, and
  `Restart=always` then cycles the unit through `activating` on its own.
- **An idle bot is one process.** Each `hermes@` cgroup holds exactly one pid (`hermes`) at rest. Terminal
  and background processes the agent starts (`tools/process_registry.py`) run as children in that cgroup,
  so more than one pid means there is work in flight that druzhok cannot otherwise see.
- **Hermes records turns in flight.** `<tenant>/gateway_state.json` carries `active_agents`
  (`_active_work_count()`: running agents + cron runs + API runs), rewritten at every turn boundary, and
  `gateway_state` (`running`, `draining`, ...).
- **Hermes's own scale-to-zero does not apply.** `gateway/scale_to_zero.py` arms only for the Nous-hosted
  relay connector (relay-only messaging plus a registered `wakeUrl`) and suspends a Fly machine. Its idle
  predicate is a useful reference for what counts as work, and the checks below mirror it from outside.
- **No bot has cron jobs.** Every `cron/jobs.json` on the box is `{"jobs": []}`. Kanban tables are empty;
  `/goal` is an admin command tenants cannot run.
- **A planned stop drains.** `HERMES_RESTART_DRAIN_TIMEOUT=30`: a turn running at SIGTERM is given 30 s
  to finish (relay canary). On shutdown Mnemosyne runs its session-end consolidation.
- **Two BEAMs write the DB.** druzhok.service and one-off `ops/druzhok-run.sh` BEAMs (where restarts and
  `set_mode` are run by hand) are not clustered, so `:global` locks do not span them. The existing
  `{:bot_restart, name}` lock only serialises restarts inside one BEAM. Everything sleep/wake needs to
  exclude is therefore decided by conditional updates of the instance row.
- **nft elements are re-added only on start.** `druzhok-ctl start` adds the bot's `bot_uids` and
  `bot_webhook` elements; an nftables reload or reboot empties the sets until the next start.

## State

`instances.active` keeps its meaning: someone wants this bot running. Sleep adds a `power` column and its
bookkeeping:

| column | type | meaning |
|---|---|---|
| `power` | string, default `"awake"` | `awake`, `sleeping` (going to sleep), `asleep`, `waking` |
| `power_since` | utc_datetime | when `power` last changed |
| `pending_op` | string, nil | `start` or `restart` asked for during a transition, run when it ends |
| `started_at` | utc_datetime | last successful start (any path) |
| `wake_error` | string, nil | why the last wake failed; cleared by a successful start |
| `wake_failed_at` | utc_datetime, nil | for the 60 s retry cooldown, shared by both BEAMs |
| `sleep_enabled` | boolean, default false | per-bot opt-in |

Global `Settings` key `sleep_idle_minutes` (default 30) is the idle window.

**Every change of `power` is a compare-and-set**: `UPDATE instances SET power = $to, power_since = now
WHERE id = $id AND power = $from [AND ...]`, and the caller acts only if one row changed. That is the
whole of the mutual exclusion. Whoever wins a CAS out of a stable state (`awake`, `asleep`) into a
transition (`sleeping`, `waking`) is that transition's **owner** and must finish it with a second CAS.

What the dashboard and the manager bot show:

| `active` | `power` | unit | shown as |
|---|---|---|---|
| true | awake | active | running |
| true | awake | activating | starting |
| true | awake | inactive / failed | down (a real failure, unchanged) |
| true | sleeping | any | falling asleep |
| true | asleep | inactive | **sleeping** (with `wake_error`: "wake failed: …, retrying") |
| true | asleep | activating / active | reconciled to `awake` by the sweep ([Reconcile](#reconcile)) |
| true | waking | any | waking |
| false | awake | inactive | stopped |
| false | awake | active / activating | stopping |
| false | sleeping / waking | any | stopping (the owner stops it when the transition ends) |

`false | asleep` cannot happen: `stop/1` turns `asleep` into `awake` in the same update that clears
`active` ([Stop, start, restart](#stop-start-restart)).

## Falling asleep

`Druzhok.Sleep` (a GenServer in the relay's supervisor, so only in the BEAM that serves the endpoint,
`Phoenix.Endpoint.server?`) sweeps once a minute. A bot is a candidate when all of these hold:

1. `active`, `sleep_enabled`, `telegram_mode == "webhook"`, `power == "awake"`, `pending_op` nil, and the
   relay is not paused for any reason.
2. `started_at` is set and older than the idle window. A sweep that finds an awake, running bot with
   `started_at` nil (every bot at deploy time) sets it to now, so it can become a candidate one window
   later.
3. No `telegram_updates` row for it with `received_at` inside the window, and none pending.
4. No `usage_logs` row for it inside the window. Every LLM, search, scrape, image and embedding call goes
   through the proxy, so this covers work that Telegram does not show: a long turn, a delegation, a
   background reply.
5. `gateway_state.json`: `gateway_state == "running"` and `active_agents == 0`. Unreadable or missing →
   not idle (fail awake, as hermes's own predicate does).
6. The unit is `active` and its cgroup has exactly one process (`druzhok-ctl procs <bot>`, new
   subcommand printing the count of `cgroup.procs`). More → not idle.
7. No enabled job in `cron/jobs.json` ([Cron](#cron)). Unreadable → not idle.

Then `Sleep` puts it to sleep:

1. **CAS `awake → sleeping`** with check 1 in the `WHERE` (`active AND sleep_enabled AND telegram_mode =
   'webhook' AND pending_op IS NULL AND (telegram_relay_paused_until IS NULL OR telegram_relay_paused_until
   <= now)`). No row → someone else acted; skip.
2. `Webhook.pause(id, :sleeping)`. From here new updates queue and are not delivered.
3. Re-read the row and re-run checks 1–7 (check 1 now expecting `power == "sleeping"`). Anything changed
   → abort: `Webhook.resume_if(id, :sleeping)`, CAS `sleeping → awake`, `Relay.notify`, then run
   `pending_op` if set ([Ending a transition](#ending-a-transition)).
4. `Host.stop(name)`. The 30 s drain covers a turn that slipped in before the pause.
5. CAS `sleeping → asleep`, `Webhook.resume_if(id, :sleeping)`, `Relay.notify`, then
   [end the transition](#ending-a-transition). If updates queued during steps 2–4, the relay now sees
   them for an asleep bot and wakes it.

`power` reads `sleeping` before the unit is touched, so a crash or a druzhok deploy anywhere in steps 2–5
leaves a row the [reconcile](#reconcile) pass resolves; it never leaves an `awake` row with a stopped unit.

`resume_if(id, reason)` is new: it clears the pause only when `telegram_relay_pause_reason` is that
reason (one conditional update), so a `wrong_owner` or `rejected_config` pause set meanwhile survives.

There is no hand-run "sleep now" entry point. Testing uses a short `sleep_idle_minutes`; a transition is
owned only by druzhok.service.

## Waking

In the relay worker, a pending row for an instance with `active` and `power == "asleep"` calls
`Druzhok.Sleep.wake(id)` and re-polls in 1 s instead of posting. A row for an instance with
`power == "waking"` goes down the **normal delivery path** (owner check, POST) with the retry backoff
capped at 1 s, so it is delivered the moment the listener is up (~5 s), not at READY. `sleeping` keeps the
existing pause behaviour (held). Pause handling is unchanged and comes first, but a sleeping bot carries no
pause other than its own: check 1 refuses a paused bot, and nothing posts to an asleep one.

`Sleep.wake/1`:

1. **CAS `asleep → waking`** `WHERE active AND (wake_failed_at IS NULL OR wake_failed_at < now - 60 s)`.
   No row → already waking, stopped, or cooling down after a failure; nothing to do.
2. In a `Task` under the relay's supervisor: `BotManager.start/1`'s body (config sync, `Host.start`).
   `druzhok-ctl start` re-adds the nft elements.
3. Success: CAS `waking → awake` setting `started_at = now`, `wake_error = nil`, `wake_failed_at = nil`.
   Failure: CAS `waking → asleep` setting `wake_error`, `wake_failed_at = now`; log an error. The worker
   asks again on its next poll after the cooldown; updates keep waiting under the 24 h expiry.
4. [End the transition](#ending-a-transition).

`start/1`'s existing `after` block (`Webhook.resume` + `Relay.notify`) runs as it does for any start.

### Typing indicator

When a wake's CAS wins, druzhok sends `sendChatAction(chat_id, "typing")` with the bot's own token for the
chat of the update that caused it (message, edited message or callback query; other update types have no
chat to show it in), and repeats it every 4 s until that row is acked or 60 s pass. Telegram shows
"typing…" for 5 s per call. Druzhok, not the bot, has internet, so this needs no egress change. A failed
call is logged at debug and ignored.

### Wake latency

From update to delivery ≈ 5–7 s (listener up) plus druzhok's start overhead (`sync_config`, `chown -R` of
the tenant tree, 0.1–1 s). The reply itself is one normal turn on top. Rollout step 2 measures whether a
turn delivered before READY waits for the 20 s model warm-up; if it does, the first reply after a wake is
~25 s late and finding that gap moves from follow-up to blocker.

## Ending a transition

The owner of a `sleeping` or `waking` transition, after its final CAS, re-reads the row and:

- `active == false` (a Stop arrived meanwhile): `Host.stop`, set `power = awake`, `pending_op = nil`.
- `pending_op == "restart"`: clear it, then `BotManager.restart/1`. A restart asked for during a wake
  (a settings save) therefore runs after the wake, with the config written in between; one asked for
  during a sleep wakes the bot.
- `pending_op == "start"`: clear it; if the bot ended `asleep`, wake it.

## Stop, start, restart

- **`stop/1`**: one update, `SET active = false, pending_op = NULL, power = CASE power WHEN 'asleep' THEN
  'awake' ELSE power END`. Then, if `power` was `awake` or `asleep`, the existing pause + `Host.stop`.
  If it was `sleeping` or `waking`, nothing more: the owner sees `active == false` when its transition
  ends and stops the unit. An asleep bot that is stopped is never woken: the worker and `wake/1` require
  `active`.
- **`start/1`**: `asleep` → a wake (`Sleep.wake/1`'s CAS and body, run in the caller). `sleeping` or
  `waking` → set `pending_op = "start"` (conditional on `power` still being that state, else re-dispatch)
  and return `{:ok, name}`. `awake` → today's start, which also writes `started_at`.
- **`restart/1`**: `asleep` → a wake; the bot falls asleep again one idle window later. This keeps a token
  or secret change working: the wake re-registers the webhook. `sleeping` or `waking` → `pending_op =
  "restart"`. `awake` → today's restart.
- **`Webhook.set_mode/3`** is unchanged: every caller restarts afterwards, and the restart wakes an asleep
  bot. A polling bot is never a candidate, and the reconcile pass wakes an asleep polling bot in case a
  caller forgot.

A wake run in a `druzhok-run.sh` BEAM owns its transition like any other; if that BEAM dies mid-wake the
reconcile pass resolves it.

## Reconcile

Each sweep, and once at `Sleep` start, resolves rows whose state disagrees with the unit:

- `sleeping` or `waking` with `power_since` older than 5 min (at `Sleep` start: any age not owned by a
  live `druzhok-run.sh` wake, i.e. also older than 5 min for `waking`; a `sleeping` row is only ever
  owned by druzhok.service, so at its start every one is stale): unit `active` → CAS to `awake` (and
  `resume_if(:sleeping)`); unit `activating` → leave it for the next sweep; unit inactive/failed → CAS to
  `asleep`. Then end the transition as above.
- `asleep` with the unit `active` or `activating` (an auto-restart after a failed wake succeeded, or a
  hand-run `druzhok-ctl start`) → CAS to `awake`, `started_at = now`.
- `asleep` with `telegram_mode == "polling"` → wake.
- `awake`, active, running, `started_at` nil → set it (check 2).

Five minutes is well above a normal transition (30 s drain, ~26 s start). A start can legitimately take
up to `TimeoutStartSec=300`; it is `activating` all that time and the rule above leaves it alone, so a
slow start is never cut short.

## Reboot

The DB survives. Asleep bots stay asleep and wake on their next update; their nft elements, emptied by
the reboot, come back with that start. Bots that were awake are `active`, `power == "awake"`, unit inactive:
shown as down, as today. A pending row for such a bot is not a wake trigger, because the same state is a
bot that crashed, and waking it on every update would hide a crash loop. Starting every active, awake bot
on druzhok boot is the follow-up that closes this.

## Cron

A bot with any enabled job in `cron/jobs.json` is never a candidate (check 7), so cron works exactly as
today. A job is created only during a turn, so an asleep bot cannot gain one. v2, when a bot uses cron:
wake ~2 min before the earliest `next_run_at` from the same file. Not built now because no bot has a job
and hermes's catch-up rules for a job overdue at boot would need their own testing.

## Visibility

- Dashboard: the states in the table above, a per-bot "Sleep when idle" toggle in the settings tab next to
  "Telegram delivery" (disabled with a hint for a polling bot), and `power_since`, `started_at` and
  `wake_error` in the delivery card.
- Manager bot: the owner's bot list shows `💤 спит` for an asleep bot, not "stopped".
- `ops/smoke.sh` on an asleep bot prints `asleep since <ts>`, runs the checks that need no process
  (webhook registered to druzhok, Telegram's `pending_update_count`, no row older than 24 h, no pause
  other than `sleeping`) and skips the unit, nft and listener-owner checks: a stopped bot has no egress or
  port to guard, and its elements come back on start. It exits 0 if those pass.
- Logs: `[sleep] <bot>: asleep after <n> min idle (rss <mb> MB)`,
  `[sleep] <bot>: woken by update <id>, delivered after <s> s`, `[sleep] <bot>: wake failed: <reason>`,
  and one line per reconcile action.

## Rollout

1. Deploy with every bot `sleep_enabled = false`. Migration adds the columns; nothing else changes. The
   first sweep fills `started_at` for running bots.
2. Measure the pre-READY turn on igorhermes ([Wake latency](#wake-latency)).
3. Enable igorhermes with `sleep_idle_minutes` temporarily at 2. Test: falls asleep; a DM wakes it and is
   answered, delivered before READY; two messages sent while asleep are both answered in order; a voice
   note wakes it; a message sent during the sleep transition is answered; dashboard Stop on an asleep bot
   keeps it down through a later message; Stop during a wake leaves it stopped; restart on an asleep bot
   wakes it; a settings save during a wake is applied after it; `systemctl restart druzhok` during a
   sleep and during a wake ends in a consistent state; smoke passes asleep and awake. Then back to 30.
4. Enable the other bots one at a time.

## Rollback

Per bot: `sleep_enabled = false`, then `BotManager.start` if asleep. All bots: the same in one query and a
loop. The relay works unchanged with every bot `awake`.

## Risks

- **A background job that neither calls the proxy nor shows as a process.** For example an `asyncio` task
  inside hermes waiting on a timer to post later (a reminder without cron). Check 5 only covers turns.
  Accepted for v1: tenants have no scheduling tool other than cron, which check 7 covers.
- **Wake storms.** A group bot that observes every message wakes on each one. That is a bot which is not
  idle, and the idle window keeps it awake; it costs at most one start per window.
- **Session-end consolidation on every sleep.** Mnemosyne consolidates when the gateway stops: an
  embeddings call per sleep, priced at 0 in ruoc today.
- **First reply after a wake is slower.** 5–7 s best case, ~25 s if turns wait for READY. The typing
  indicator covers the wait. A bot whose owner minds stays opted out.
- **The restart lock stays per BEAM.** Two restarts from different BEAMs can still overlap, as today.
  Sleep and wake do not rely on it.

## Alternatives considered

- **Hermes's native scale-to-zero.** Built for the Nous relay connector and Fly machine suspend; needs
  relay-only messaging and a wake URL. Would need fork patches to arm with a direct webhook, and hermes
  would then stop itself outside druzhok's CAS, racing restart and the relay.
- **Freezing instead of stopping** (`systemctl freeze`, cgroup freezer). Wake in milliseconds, but a frozen
  process keeps all its RAM, which is the point of sleeping.
- **A lease or lock table instead of CAS on `power`.** Same guarantee with an extra expiry to manage; the
  state column is needed for display anyway.
- **`restart/1` as a no-op on an asleep bot** (r1). Breaks token changes (the webhook is registered only on
  start) and loses settings saved during a wake.

## Tests

- CAS: two concurrent `wake/1` → one start; `wake/1` vs `stop/1` → no start after the stop; a sweep vs a
  restart → one of them, never both.
- `Druzhok.Sleep`: candidate selection for each of checks 1–7 (fixtures for `gateway_state.json`,
  `jobs.json`, a stub for `procs`, rows in `telegram_updates` and `usage_logs`); `started_at` nil is filled
  and is not a candidate; the sequence aborts when a row arrives between the CAS and the re-check;
  `resume_if` keeps a `wrong_owner` pause set meanwhile.
- Ending a transition: Stop during `sleeping` and during `waking`; `pending_op` restart and start.
- Reconcile: stale `sleeping` and `waking` with the unit active and inactive; `asleep` with the unit active;
  asleep polling bot; boot reconcile of any age.
- `BotManager`: `stop/1` on asleep sets `awake` + inactive; `restart/1` and `start/1` on asleep wake;
  during a transition they set `pending_op`; failed wake records `wake_error` and honours the cooldown.
- Relay worker: asleep row calls `wake`, no POST; waking row is posted as soon as the stub listener is up;
  no wake for `active == false`.
- Typing indicator: sent for a message update, not for an update without a chat; stops at ack.
- `ops/druzhok_ctl_test`: `procs` prints the cgroup count, refuses an unknown bot.
- smoke: an asleep bot passes; the skipped checks are named in the output.

## Follow-ups (not in this change)

- Start every `active`, `awake` bot on druzhok boot (reboot recovery for awake bots).
- Cron wake (v2 above).
- Find the 20 s between `Gateway running` and READY (a blocker if rollout step 2 shows turns wait for it).
- Side finding: one-off `druzhok-run.sh` BEAMs start their own `ManagerBot` poller, which fights the
  service's (`409 Conflict: terminated by other getUpdates request` in the druzhok journal during every
  run). The one-off BEAM should not start `ManagerBot`.
