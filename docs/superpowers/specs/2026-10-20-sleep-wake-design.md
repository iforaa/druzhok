# Bot sleep/wake

Status: draft r1, 2026-10-20. Branch `sleep-wake`. Block A item 6. Builds on the Telegram webhook relay
(`2026-10-20-telegram-webhook-relay-design.md`).

## Goal

A bot that has had nothing to do for a while is stopped ("asleep"). The next Telegram update for it starts
it again ("wake"), and the update is delivered once it listens. Nobody loses a message, and to the user
a sleeping bot only shows as a slower first reply.

What this buys:

1. **RAM.** A fresh hermes is ~230 MB (`MemoryCurrent` after today's restarts) and grows toward the
   800M/1G per-bot limits with use. Over the last 7 days the six bots had LLM traffic in 2–26 distinct
   hours each (`usage_logs`), so most of them are idle almost all the time. Sleeping is what lets one
   host carry many more bots than the 5 GB `system-hermes.slice` fits awake.
2. **Recovery after a reboot.** `hermes@` units are not enabled (`systemctl is-enabled` → disabled), so
   nothing starts bots after the box reboots. The wake path starts any bot druzhok believes should be up
   when its first update arrives.

Non-goals: waking for cron (v1 keeps bots that have cron jobs awake, see [Cron](#cron)), sleeping polling
bots, multi-host placement (Block B), cutting hermes cold-start time (a side finding, see
[Wake latency](#wake-latency)).

## Facts this design rests on

Checked on the box and in the hermes 0.22.2 source on 2026-10-20.

- **Telegram keeps pushing to a stopped bot's webhook.** Hermes calls `setWebhook` on connect and never
  calls `deleteWebhook` on disconnect, so updates for a stopped bot land in `telegram_updates` and wait
  (relay spec, 24 h expiry). `drop_pending_on_cold_boot: false` keeps them across the cold boot.
- **Hermes listens ~5 s after start, systemd reports ready ~26 s after start.** igorhermes and vilya_fe6f
  boots today: `Starting` → `Webhook server listening` 4.6–5.2 s → `Gateway running` ~6 s → 20 s gap →
  model-context warm → `READY=1` at 22–26 s. The unit is `Type=notify`, so `systemctl start`, and with it
  `BotManager.start/1`, returns only at READY.
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

## States

`instances.active` keeps its meaning: the operator (or owner) wants this bot running. A new column
`instances.sleeping_since` (utc_datetime, nil = awake) marks a bot druzhok stopped on purpose.

| `active` | `sleeping_since` | unit | shown as |
|---|---|---|---|
| true | nil | active | running |
| true | set | inactive | **sleeping** |
| true | set | activating/active | waking |
| false | nil | inactive | stopped |
| true | nil | inactive/failed | down (unchanged: a real failure) |

New per-bot column `instances.sleep_enabled` (boolean, default false) opts a bot in. One global setting,
`Settings` key `sleep_idle_minutes` (default 30), is the idle window. Opt-in per bot so the rollout goes
one bot at a time, as with the relay.

## Falling asleep

`Druzhok.Sleep` (a GenServer in the relay's supervisor, so only in the BEAM that serves the endpoint,
`Phoenix.Endpoint.server?`) sweeps once a minute. A bot is a candidate when all of these hold:

1. `active`, `sleep_enabled`, `telegram_mode == "webhook"`, `sleeping_since` nil, unit `active`.
2. Started at least the idle window ago (`instances.started_at`, new column, written by `do_start` on
   success). A just-woken or just-restarted bot is never put back to sleep at once.
3. No `telegram_updates` row for it with `received_at` inside the window, and none pending.
4. No `usage_logs` row for it inside the window. Every LLM, search, scrape, image and embedding call goes
   through the proxy, so this covers work that Telegram does not show: a long turn, a delegation, a
   cron run, a background reply.
5. `gateway_state.json`: `gateway_state == "running"` and `active_agents == 0`. Unreadable or missing →
   not idle (fail awake, as hermes's own predicate does).
6. The unit's cgroup has exactly one process (`druzhok-ctl procs <bot>`, new subcommand: the count of
   `cgroup.procs`). More → not idle.
7. No enabled cron job ([Cron](#cron)).

Then `BotManager.sleep/1`:

1. Take the per-bot lock `restart/1` already uses (`{:bot_restart, name}`), so sleep, restart and wake
   never overlap. Lock busy → skip this sweep.
2. `Webhook.pause(id, :stopping)`: from here new updates queue and are not delivered.
3. Re-check 3–6. Anything arrived or started since the sweep → `Webhook.resume`, `Relay.notify`, abort.
4. `Host.stop(name)` (30 s drain covers a turn that slipped in before the pause).
5. Set `sleeping_since = now`, keep `active = true`, then `Webhook.resume` and `Relay.notify`. If updates
   queued during steps 2–4, the relay now sees them for a sleeping bot and wakes it at once.

`sleep/1` is also callable by hand (`druzhok-run.sh`) for testing, skipping the idle checks only when
called with `force: true`.

## Waking

The relay worker gets one new branch, before delivery. When it finds a pending row for an instance with
`active` and `sleeping_since` set, it calls `Druzhok.Sleep.wake(id)` and polls the row again in 1 s
instead of trying to POST.

`Sleep.wake/1` is deduplicated per bot (one wake at a time; another wake for the same bot within 60 s of
a failed one is refused, so a broken bot is not restarted every second). It runs in a `Task` under the
relay's supervisor and calls `BotManager.start/1` under the per-bot lock. `do_start` clears
`sleeping_since` and writes `started_at` only on success.

While the start blocks waiting for READY, the worker keeps polling: the listener is up after ~5 s, the
owner check passes and the row is delivered then, ~20 s before `start/1` returns. Backoff while a wake is
in progress is capped at 1 s; the normal 1→30 s backoff applies again once the bot is awake.

A wake that fails (start error, unit `failed`) leaves `sleeping_since` set, logs an error and is retried
on the worker's next poll after the 60 s cooldown. Updates keep waiting under the 24 h expiry. The
dashboard shows the bot as down with a "wake failed" note.

### Typing indicator

When a wake starts, druzhok sends `sendChatAction(chat_id, "typing")` with the bot's own token for the
chat of the update that caused it (message, edited message or callback query; other update types have no
chat to show it in), and repeats it every 4 s until that row is acked or 60 s pass. Telegram shows
"typing…" for 5 s per call. Druzhok, not the bot, has internet, so this needs no egress change. A failed
call is logged at debug and ignored.

### Wake latency

From update to delivery ≈ 5–7 s (listener up) plus druzhok's start overhead (`sync_config`, `chown -R` of
the tenant tree, 0.1–1 s). The reply itself is one normal turn on top. Before rollout, measure on
igorhermes whether a turn delivered before READY waits for the 20 s model warm-up; if it does, the first
reply after a wake is ~25 s late and the warm-up becomes worth chasing (side finding: the 20 s gap after
`Gateway running` is before the `/v1/models` probes, which druzhok answers in milliseconds).

## Interaction with existing operations

- **`BotManager.stop/1`** (dashboard Stop, delete): also clears `sleeping_since`. A stopped bot is never
  woken: the worker wakes only when `active` is true.
- **`BotManager.start/1`** on a sleeping bot: an ordinary start; it clears `sleeping_since`.
- **`BotManager.restart/1`** on a sleeping bot: no-op returning `{:ok, name}`. Every caller restarts to
  apply config or a new hermes, and a wake runs `sync_config` and starts on `/opt/hermes` anyway. The
  update-hermes rollout therefore moves sleeping bots onto the new version at their next wake.
- **Mode switch to polling**: `Webhook.set_mode(_, "polling")` on a sleeping bot is followed by a restart,
  which is a no-op above, so the bot would stay asleep with nothing to wake it. `set_mode` to polling
  therefore clears `sleeping_since` and starts the bot. A polling bot is never a sleep candidate.
- **Relay pause reasons**: `:stopping` is reused during the sleep transition; `wrong_owner` and
  `rejected_config` pauses still hold delivery, and a wake does not lift them (`start/1` already resumes
  them on the next real start).
- **Reboot**: the DB is unchanged, so sleeping bots stay asleep and wake on their next update. Bots that
  were awake are now `active`, `sleeping_since` nil, unit inactive. v1 treats that as down, as today. A
  pending row for such a bot is not a wake trigger (that would also restart crashed bots in a loop).
  Starting all active bots on druzhok boot is a separate small change, listed under follow-ups.

## Cron

A bot with any enabled job in `cron/jobs.json` is never a sleep candidate (check 7), so cron keeps working
exactly as today. A job is created only during a turn, so a sleeping bot cannot gain one. v2, when a bot
actually uses cron: a sleeping bot is woken ~2 min before its earliest `next_run_at`, read from the same
file. Not built now because no bot has a job and hermes's catch-up rules for a job overdue at boot would
need their own testing.

## Visibility

- Dashboard: status `sleeping` (💤) and `waking`, from the table in [States](#states); a per-bot
  "Sleep when idle" toggle in the settings tab next to "Telegram delivery", disabled with a hint for a
  polling bot; `sleeping_since` and the last wake time in the delivery card.
- Manager bot: the owner's bot list shows `💤 спит` for a sleeping bot, not "stopped".
- `ops/smoke.sh` on a sleeping bot prints `sleeping since <ts>` and exits 0 after the checks that need no
  running process (nft elements, webhook registration, queue age, pause). The listener-owner check is
  skipped while asleep.
- Logs: `[sleep] <bot>: asleep after <n> min idle (rss <mb> MB)` and
  `[sleep] <bot>: woken by update <id>, listening after <s> s`.

## Rollout

1. Deploy with every bot `sleep_enabled = false`. Nothing changes.
2. Measure the pre-READY turn on igorhermes ([Wake latency](#wake-latency)).
3. Enable igorhermes with `sleep_idle_minutes` temporarily at 2. Test: falls asleep; a DM wakes it and is
   answered; two messages sent while asleep are both answered in order; a voice note wakes it; a message
   sent during the sleep transition (steps 2–4) is answered; dashboard Stop on a sleeping bot keeps it
   down through a later message; restart on a sleeping bot keeps it asleep. Then back to 30.
4. Enable the other bots one at a time. The smoke check passes asleep and awake.

## Rollback

Per bot: `sleep_enabled = false` and `BotManager.start`. All bots: the same in one query. Nothing else
in the relay depends on sleep.

## Risks

- **A background job that neither calls the proxy nor shows as a process.** For example an
  `asyncio` task waiting on a timer inside hermes that will post later (a reminder without cron). Check 5
  only covers turns. Accepted for v1: tenants have no scheduling tool other than cron, which check 7
  covers.
- **Wake storms.** A group bot that observes every message wakes on each one. That is a bot which is not
  idle and the idle window keeps it awake; it costs at most one start per window.
- **Session-end consolidation on every sleep.** Mnemosyne consolidates when the gateway stops. That is an
  embeddings call per sleep, priced at 0 in ruoc today.
- **First reply after a wake is slower.** 5–7 s best case, ~25 s if turns wait for READY. The typing
  indicator covers the wait. A bot whose owner minds can stay opted out.
- **The idle checks race a new update.** Covered by pausing before the re-check and by the drain.

## Alternatives considered

- **Hermes's native scale-to-zero.** Built for the Nous relay connector and Fly machine suspend; needs
  relay-only messaging and a wake URL. Would need fork patches to arm with a direct webhook, and hermes
  would then stop itself without druzhok's lock, racing restart and the relay.
- **Freezing instead of stopping** (`systemctl freeze`, cgroup freezer). Wake in milliseconds, but a frozen
  process keeps all its RAM, which is the point of sleeping. Swap would be needed to gain anything.
- **Idle by Telegram traffic alone.** Misses long turns, delegations and background processes; checks
  4–6 exist for those.

## Tests

- `Druzhok.Sleep`: candidate selection for each of checks 1–7 (fixtures for `gateway_state.json`, a stub
  for `procs`, rows in `telegram_updates` and `usage_logs`); the sleep sequence aborts when a row arrives
  between the sweep and the re-check; lock busy → skipped.
- `BotManager`: `sleep/1` sets `sleeping_since` and keeps `active`; `stop/1` clears it; `restart/1` on a
  sleeping bot does not call `Host`; `start/1` clears it and writes `started_at`; a failed start keeps it.
- Relay worker: a pending row for a sleeping bot calls `wake` and no POST; no wake for `active == false`;
  wake dedup and the 60 s cooldown; the row is delivered once the stub listener comes up.
- Typing indicator: sent for a message update, not for an update without a chat; stops at ack.
- `Webhook.set_mode` to polling on a sleeping bot clears `sleeping_since` and starts it.
- `ops/druzhok_ctl_test`: `procs` prints the cgroup count, refuses an unknown bot.
- smoke: a sleeping bot passes.

## Follow-ups (not in this change)

- Start every `active`, non-sleeping bot on druzhok boot (reboot recovery for awake bots).
- Cron wake (v2 above).
- Find the 20 s between `Gateway running` and READY.
- Side finding: one-off `druzhok-run.sh` BEAMs start their own `ManagerBot` poller, which fights the
  service's (`409 Conflict: terminated by other getUpdates request` in the druzhok journal during every
  run). The one-off BEAM should not start `ManagerBot`.
