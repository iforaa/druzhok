# Telegram webhook relay

Status: draft r3, 2026-10-20 (reviewed by revmux `telegram-webhook-relay/01-initial`, `02-after-fix`). Branch
`telegram-webhook-relay`. Block A item 5; item 6 (sleep/wake) builds on it.

## Goal

Telegram delivers every bot's updates to druzhok, which stores them and relays them to the bot. Bots stop
long-polling `getUpdates`.

What this buys:

1. **No lost messages on restart.** Today every bot start is a hermes *cold boot*, which calls Telegram with
   `drop_pending_updates=true` (`platforms.telegram.extra.drop_pending_on_cold_boot` defaults to true; the
   prod logs show `Cold boot: dropping Telegram updates queued while offline` on every restart, including the
   0.22.2 rollout). A message sent during a deploy, an OOM restart or an upgrade is silently gone.
   With the relay, druzhok holds every update the bot has not yet received and delivers it when the bot is
   back (see [Delivery guarantee](#delivery-guarantee) for what a crash can still lose).
2. **A queue druzhok owns.** This is the precondition for item 6: a stopped bot's messages wait in druzhok,
   which can then start the bot and deliver them. Without it, a sleeping bot either keeps a poller running
   (no RAM saved) or loses messages.
3. **Cheaper idle bots.** No long-poll socket per bot (15 Telegram connections today), no polling
   heartbeat / `getWebhookInfo` probes, no CLOSE-WAIT wedge recovery. Hermes runs those only in polling mode.

Non-goals: sleep/wake itself (item 6), moving the superbot (`Druzhok.ManagerBot`, Elixir, always on) off
polling, multi-host routing (Block B), a Bot API facade, exactly-once delivery.

## How it works

```
Telegram ──HTTPS──▶ Caddy (druzhok.oldey.dev:443) ──▶ Phoenix  POST /telegram/webhook/:bot
                                                        │ check secret header, INSERT update, 200
                                                        ▼
                                              telegram_updates (SQLite)
                                                        │ Druzhok.Telegram.Relay, one worker per bot,
                                                        │ update_id order, owner-checked listener
                                                        ▼
                                  hermes (PTB webhook server) http://127.0.0.1:<port>/telegram/webhook/<bot>
```

### Hermes side: native webhook mode, no fork patch

Hermes 0.22.2's Telegram adapter (`plugins/platforms/telegram/adapter.py`, `_start_webhook_mode`) switches to
webhook mode when `TELEGRAM_WEBHOOK_URL` is set. It then:

- starts PTB's tornado server on `TELEGRAM_WEBHOOK_HOST:TELEGRAM_WEBHOOK_PORT`, path = the URL's path;
- calls `setWebhook(url, secret_token=TELEGRAM_WEBHOOK_SECRET, allowed_updates=ALL, drop_pending_updates=…)`
  itself on every connect (so the registration is self-healing and needs no druzhok call);
- refuses to start without `TELEGRAM_WEBHOOK_SECRET`;
- answers 403 when `Content-Type` is not exactly `application/json` or the
  `X-Telegram-Bot-Api-Secret-Token` header is missing or wrong (PTB `TelegramHandler._validate_post`), 404 on
  a path other than its `url_path`, and 200 as soon as the update is on PTB's in-memory queue;
- on disconnect does **not** delete the webhook (only polling mode calls `deleteWebhook`, at start), so
  updates keep flowing to druzhok while the bot is stopped — exactly what item 6 needs;
- records the `update_id` of every update its PTB handler has *accepted* in a per-bot receipt file under its
  home (`update_admission.py` `_release_claim`, 24 h TTL) and drops a redelivered update whose id is in it,
  across restarts. The receipt is written at handoff, before debounce, the busy queue and the agent turn,
  so it is a dedupe of redeliveries, not a record of work done;
- on a stop (SIGTERM from systemd) interrupts running chat turns at once (`agent.restart_drain_timeout`
  defaults to 0), tells the user, and marks the session `resume_pending`.

Druzhok adds to `Runtime.Hermes.env_vars/1` (PORT and HOST for **every** bot — hermes reads them only in
webhook mode, and `druzhok-ctl` needs the port for the bind lock below whatever the mode; URL and SECRET only
for bots in webhook mode, which is what switches hermes over):

| Var | Value |
|---|---|
| `TELEGRAM_WEBHOOK_URL` | `https://<PHX_HOST>/telegram/webhook/<instance.name>` |
| `TELEGRAM_WEBHOOK_HOST` | `127.0.0.1` (never all interfaces) |
| `TELEGRAM_WEBHOOK_PORT` | `20000 + instance.id` |
| `TELEGRAM_WEBHOOK_SECRET` | `instances.telegram_webhook_secret` (32 random bytes, hex) |

and `drop_pending_on_cold_boot: false` to the druzhok-owned `platforms.telegram.extra` keys in
`sync_config/2` (`@telegram_extra_keys`), for **all** bots. In polling mode that alone fixes the
lost-on-restart bug: Telegram's own queue is kept through the restart. In webhook mode the flag only
matters for updates Telegram could not hand to druzhok (druzhok down).

Port: `20000 + id` is unique per row and stable; the range 20000–20999 is 1000 ports, so `id >= 1000`
refuses webhook mode with a clear error (ids are 9–26 today). Nothing on the box listens in the range
(`ss -ltn` 2026-10-20: 22, 53, 80, 443, 2019, 3306, 4000, 5432, 8787, 9091, one ephemeral beam port).

### Druzhok side

**Schema** (one migration):

- `instances.telegram_mode` — `"polling"` (default) | `"webhook"`. Per bot, so rollout and rollback are one bot
  at a time.
- `instances.telegram_webhook_secret` — generated on the first switch to webhook, kept afterwards.
- `instances.telegram_relay_paused_until`, `telegram_relay_pause_reason` — the relay pause. It is a column, not
  process state, because `BotManager.stop/restart` usually runs in a one-off `ops/druzhok-run.sh` BEAM, which
  must be able to pause and resume the relay running inside druzhok.service.
- `telegram_updates`: `id`, `instance_id`, `update_id` (Telegram's), `payload` (raw JSON text), `received_at`,
  `acked_at` (the bot answered 2xx; null = pending), `attempts`, `last_error`, `dropped_reason`
  (null | `expired` | `rejected` | `mode_switch`, the last from a forced switch back to polling). Unique index `(instance_id, update_id)`; index
  `(instance_id, acked_at, update_id)`.

**Ingress** — `DruzhokWebWeb.TelegramWebhookController`, route `POST /telegram/webhook/:bot` in its own
pipeline (no session, no CSRF; JSON body):

1. Look up the instance by name; unknown or not in webhook mode → 404 (visible in
   `getWebhookInfo.last_error_message`).
2. `Plug.Crypto.secure_compare` of `x-telegram-bot-api-secret-token` with the stored secret; mismatch → 401.
3. `INSERT … SELECT … FROM instances WHERE id = ? AND telegram_mode = 'webhook' ON CONFLICT (instance_id,
   update_id) DO NOTHING` with the re-encoded body (Telegram redelivers when an ack is late; the unique index
   makes that a no-op). The mode check is in the insert itself, and the switch to polling is one
   `UPDATE … WHERE NOT EXISTS (pending rows)`, so the two cannot interleave: a row is never stored for a bot
   that already polls (that insert stores nothing → 404, Telegram keeps the update for the polling bot).
4. 200 with an empty body, then `Relay.notify(instance_id)`. The handler never waits on the bot.

A 200 only after the row is committed is what makes the queue durable: if the insert fails, Telegram gets a
5xx and retries (it keeps updates up to 24 h).

**Relay** — `Druzhok.Telegram.Relay`: a `Registry` + `DynamicSupervisor`, one worker per webhook-mode bot,
started on boot for every such bot and on `notify/1`. It is started by `DruzhokWeb.Application`, next to the
endpoint, so the one-off `druzhok-run.sh` BEAM (which starts only `:druzhok`) never runs a second relay over
the same rows; `notify/1` is a no-op where no relay runs. Each worker re-reads its instance row before every
step, so a pause, a mode switch or a secret rotation written by another BEAM applies at once, and polls the
pause every 2 s while paused.

- **Order.** Delivers that bot's pending rows in `update_id` order, one in flight at a time. Telegram may
  push over parallel connections (hermes does not pass `max_connections`, PTB's default is 40), so arrival
  order and insert `id` can disagree with `update_id`, which is the order Telegram defines. (Telegram may
  restart update ids after a week of silence; any row that old has long expired, see housekeeping.)
- **Owner check, before every POST.** The worker reads `/proc/net/tcp` for the listener on
  `127.0.0.1:<port>` and delivers only if its uid is the bot's own (`bot-<name>`). Wrong owner → the row
  stays pending, the worker pauses, logs an error naming the owning uid, and retries in 30 s. This is the
  in-process half of the port isolation below.
- **Request.** `POST http://127.0.0.1:<port>/telegram/webhook/<name>`, headers exactly
  `content-type: application/json` and `x-telegram-bot-api-secret-token: <secret>`, body = payload, 10 s
  timeout (Finch, existing pool).
- **Outcomes.**
  - 2xx → set `acked_at`, next row.
  - Connection refused, timeout, 5xx, 429 → `attempts += 1`, `last_error`, back off 1 s → 2 s → … → 30 s cap,
    retry the same row (the bot is restarting; the head of the line waits).
  - 403 or 404 → a *configuration* fault, not a bad row: PTB answers these for every update when the secret,
    the content type or the path disagree with the bot's env. Keep the row pending, pause the worker with
    `last_error`, log an error, retry every 5 min. Fixing the config (normally a `BotManager.restart`, which
    re-syncs the env) resumes delivery with nothing lost; the 24 h expiry still applies.
  - Any other 4xx (400 malformed payload) → this row is bad: set `dropped_reason = rejected`, `acked_at`,
    log, next row. A bad row cannot block the bot forever.
- **Pause around planned stops.** `BotManager.stop/1` calls `Webhook.pause(instance_id, :stopping)` (a DB write) before stopping
  hermes, so nothing is handed to a bot that is shutting down (its listener still answers 200 and then
  rejects or drops new work). `BotManager.start/1` calls `Webhook.resume/1` unconditionally — in an `after`
  around the start attempt, whatever its outcome, so the relay does not spend its backoff on a bot still
  coming up — so every path that starts a bot (dashboard Start, `restart/1`, which is `stop` + `start`)
  clears it. A pause also lifts by itself after 5 min, so a stop
  done outside `BotManager` that never sees a `start` cannot strand the queue; a bot that is really down then
  just gets connection-refused backoff with rows pending, as designed. A worker has one pause with a reason
  (`stopping`, `wrong_owner`, `rejected_config`); `resume/1` clears whichever is set, and a fault that is
  still there pauses it again on the next attempt, so a restart is also the retry for a config fault.
- **Housekeeping, hourly** (`Relay.Housekeeper`, across every bot that has rows, whatever its mode now —
  a bot switched back to polling has no worker but its old rows hold users' messages). Delete acked rows older than 3 days. Pending rows older than 24 h get
  `dropped_reason = expired` and `acked_at = now`, one log line per bot — Telegram's own 24 h retention.

Item 6 hooks in here later: a worker whose bot is stopped asks `BotManager` to start it instead of only
backing off. Not in this spec.

### Delivery guarantee

**Every update the bot has not acked is kept; an acked one is the bot's.** PTB's 200 means "on hermes's
in-memory queue", and the relay treats it as the end of the row's life — there is no replay, because hermes
writes its receipt at the same handoff and would drop a replayed update anyway.

- **While a bot is down** (stopped, restarting, crashed, asleep later): updates queue in druzhok and are
  delivered in order once it listens again. Nothing is lost. This is the case today's cold-boot drop loses.
- **Planned stop** (deploy, `BotManager.stop`/`restart`, upgrade): the relay is paused first, so no update is
  handed to a bot that is shutting down. A turn already running is interrupted by hermes's own stop path
  (user told, session `resume_pending`) — hermes's behaviour, unchanged by the relay.
- **Unplanned stop** (OOM, crash, `systemctl restart`/`druzhok-ctl restart` outside `BotManager`): an update
  the bot had acked but not finished — in its debounce buffer, busy queue or running turn — is lost, exactly
  as with polling today (`getUpdates` confirms before processing). Everything after it is queued in druzhok.
- **Duplicates:** Telegram redelivering to druzhok is absorbed by the unique index; a relay retry after a
  lost 2xx is absorbed by hermes's receipt file.

### Port isolation

Every bot can run arbitrary code as its own uid (the terminal tool), so the webhook port must be bound to
its bot at three layers — otherwise bot A can bind B's port while B restarts or sleeps, receive B's private
chats and B's secret, and then forge updates into B's queue as the operator.

1. **systemd** — `druzhok-ctl create` writes a drop-in for **every** bot (polling ones are just as able to
   squat),
   `/etc/systemd/system/hermes@<name>.service.d/webhook.conf`:
   ```
   [Service]
   SocketBindAllow=tcp:<port>
   SocketBindDeny=any
   ```
   so a bot's processes (hermes and everything its terminal spawns, same cgroup) can `bind(2)` no port but
   its own. systemd 255 on cgroup v2 (verified on the box) enforces this with a BPF cgroup hook. Outbound
   connects (Telegram, the proxy, DNS) do not call `bind(2)` and are unaffected; the canary run must confirm
   hermes's HTTP clients and DNS still work with the drop-in in place. The port is read from the bot's env
   file (`TELEGRAM_WEBHOOK_PORT`), which druzhok writes before `create`/`start`; a bot with no port (id out
   of range) gets `SocketBindDeny=any` alone. Hermes's own loop-tick witness binds an AF_UNIX socket on
   Linux (`gateway/shutdown_watchdog.py`), which the lock does not cover.
2. **nftables** — the reply rule is keyed on uid *and* port, so even a bound socket on someone else's port
   cannot answer druzhok:
   ```
   set bot_webhook { type uid . inet_service; }
   …
   # Webhook relay: replies from a bot's own PTB listener to druzhok.
   ip daddr 127.0.0.1 meta skuid . tcp sport @bot_webhook ct direction reply accept
   ```
   `druzhok-ctl` adds `{ <uid> . <port> }` next to the existing `bot_uids` element (`nft_add`) and removes it
   in `destroy`; the bootstrap reload loop refills it from the env files. `ct direction reply` only matches
   packets of a connection someone else opened, so a bot cannot use the rule to reach other local services
   by choosing its source port.
3. **druzhok** — the relay's owner check above, so a misconfigured box never sends a payload or a secret to
   the wrong uid.

The listener is still reachable by every local user, which is why the secret is required (hermes refuses
to start without one).

**Public reachability**: `druzhok.oldey.dev` resolves straight to 195.49.213.8 (no Cloudflare proxy) and
Caddy already serves it on 443, one of the four ports Telegram allows. No Caddy change. Telegram must accept
Caddy's certificate (Let's Encrypt via DNS-01, fine).

### Superbot

Unchanged, keeps polling. It is one Elixir process, has no RAM to save and never sleeps.

## Visibility

- Dashboard settings tab: mode, pending count, oldest pending age, paused reason, last error. Read-only;
  switching mode is a `mix druzhok.telegram_mode <name> webhook|polling` task plus `BotManager.restart`, not
  a UI control (UI freeze, item 7).
- `ops/smoke.sh <bot>`: for webhook bots, `getWebhookInfo` must show our URL, `pending_update_count` at most 5,
  no `last_error_message` from the last 10 min; `telegram_updates` must have no pending row older than 60 s
  and the worker must not be paused; the listener on the bot's port must be owned by `bot-<name>`; the
  drop-in and the nft element must exist.
- Log line per delivery failure streak (first failure, pause, recovery), not per retry.

## Rollout

1. Install the ops side first: `ops/nftables-druzhok.nft` (the `bot_webhook` set must exist before
   `druzhok-ctl` adds elements to it; the bootstrap reload refills `bot_uids` and `bot_webhook`), the new
   `druzhok-ctl`, `ops/smoke.sh`.
2. Deploy schema + code with every bot still `polling`, then restart the bots one by one through
   `BotManager.restart`, operator's bot first, `ops/smoke.sh` after each. Each restart brings
   `drop_pending_on_cold_boot: false` (this alone fixes the restart bug for polling bots) and the bind lock
   (`SocketBindDeny=any` + the bot's own port) — the step where an explicit `bind(2)` somewhere in hermes
   would show up, so check a reply, a web search and a voice note on the operator's bot before the rest.
3. Operator bot: `mix druzhok.telegram_mode igorhermes webhook`, `BotManager.restart`. Check:
   - hermes logs `Connected to Telegram (webhook mode)` and `Webhook server listening on 127.0.0.1:20009`;
     `getWebhookInfo.url` is ours;
   - a DM, a group message, a voice note and a photo are answered; web search and an LLM reply still work
     (outbound under `SocketBindDeny=any`);
   - as `bot-igorhermes`, binding another port (e.g. 20010) fails with EPERM;
   - **planned:** `BotManager.restart` mid-conversation, a message sent during the restart is answered after;
   - **down:** `BotManager.stop`, send two messages, `BotManager.start`; both are answered, in order;
   - **dashboard Stop then Start** leaves the worker unpaused (`pending` drains within seconds).
4. One day on the operator bot, then the other bots one at a time with `ops/smoke.sh`.

## Rollback

Per bot: set `polling`, `BotManager.restart`. Hermes's polling start calls `deleteWebhook` (required to
succeed on cold boot) and resumes `getUpdates`. Rows still pending in druzhok for that bot are not
deliverable once it polls; the mode task refuses to switch back while any are pending unless `--force`
(which reports how many are dropped). The drop-in and the nft element are harmless in polling mode and stay.

Full: all bots to polling, then revert the code. The schema additions are inert.

## Risks

- **druzhok becomes a single point for inbound messages.** It already is for every LLM call, so a druzhok
  outage already makes bots mute; with the relay, messages sent during it are delivered afterwards instead
  of answered late by a bot that cannot reach the model anyway. Telegram buffers 24 h while druzhok is down.
- **Deploy restarts of druzhok** (~20 s) delay delivery: Telegram retries what druzhok did not ack, and
  queued rows are in SQLite. Rows a bot acked just before druzhok went down are covered by the bot's own
  processing; nothing about a druzhok restart changes the bot.
- **SQLite write load**: one insert + one update per Telegram update; at today's volume (tens per hour) this
  is negligible next to `usage_logs`.
- **One poller per token** still holds: a bot running in polling mode anywhere else calls `deleteWebhook`
  and silently takes the token's updates. `getWebhookInfo` in smoke catches it.
- **Secret rotation**: write the new secret, `BotManager.restart` the bot (hermes re-registers with Telegram
  and its listener takes the new value). Until the restart the bot answers 403, which pauses the worker —
  nothing is dropped.
- **`SocketBindDeny=any` breaks something that binds explicitly** (a tool server, a library that binds
  before connecting). The canary checks the common paths; if a tool needs a port, add it to that bot's
  drop-in deliberately.
- **Hermes upgrades**: the update-hermes skill must grep `TELEGRAM_WEBHOOK_URL|_SECRET|_PORT|_HOST`,
  `drop_pending_on_cold_boot`, `_validate_post`'s status codes, where `update_admission.py` records receipts
  and `agent.restart_drain_timeout`'s default, like the other env vars and keys it checks.

## Alternatives considered

- **Druzhok as a Bot API facade** (`platforms.telegram.extra.base_url` → druzhok; druzhok serves
  `getUpdates` from its queue and proxies every other method). Bots would keep polling, but druzhok would sit
  in the path of every `sendMessage`, upload and file download — the multipart class of bugs the
  "no HTTP_PROXY" rule exists for — for no gain over native webhook mode.
- **druzhok calls `setWebhook` itself and bots stay unaware.** Hermes in polling mode deletes any webhook at
  start, so this needs webhook mode on the bot side anyway.
- **Unix socket in the tenant dir instead of a TCP port** (PTB supports `unix=`). Filesystem permissions
  would replace layers 1–2 of the port isolation, but hermes does not expose the option, so it costs a fork
  patch kept across every upgrade. Worth revisiting if upstream adds `TELEGRAM_WEBHOOK_UNIX`.

## Tests

- Controller: valid secret → row + 200; wrong/missing secret → 401, no row; unknown bot / polling bot → 404;
  duplicate `update_id` → 200, still one row; insert failure → 5xx.
- Relay, against a Bypass server that **enforces PTB's rules** (403 unless the content type is exactly
  `application/json` and the secret matches, 404 on another path): rows inserted out of order are delivered
  in `update_id` order; head-of-line retry with backoff on refused/5xx/429, then delivery; 403/404 pause the
  worker and keep every row pending, resume after the config is fixed; 400 marks only that row rejected;
  acked rows are never resent, including after a worker restart; `stop` pauses, `start` resumes even when
  the start fails, and `stop`→`start` as separate calls (the dashboard) ends unpaused; a pause with no
  `start` lifts after 5 min; expiry and pruning.
- Owner check: a parsed `/proc/net/tcp` fixture with the port owned by another uid → no POST, worker paused.
- `Runtime.Hermes`: webhook vars present only in webhook mode, host is 127.0.0.1, port = 20000 + id, URL uses
  `PHX_HOST`; `drop_pending_on_cold_boot: false` written for both modes; id ≥ 1000 refused.
- `druzhok-ctl` (shell test or bats): `create` writes the drop-in and the `uid . port` element from the env
  file; `destroy` removes both.
- Mode task: refuses to leave webhook mode with pending rows; generates the secret once.
