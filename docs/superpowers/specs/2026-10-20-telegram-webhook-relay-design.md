# Telegram webhook relay

Status: draft r2, 2026-10-20 (r1 reviewed by revmux `telegram-webhook-relay/01-initial`). Branch
`telegram-webhook-relay`. Block A item 5; item 6 (sleep/wake) builds on it.

## Goal

Telegram delivers every bot's updates to druzhok, which stores them and relays them to the bot. Bots stop
long-polling `getUpdates`.

What this buys:

1. **No lost messages on restart.** Today every bot start is a hermes *cold boot*, which calls Telegram with
   `drop_pending_updates=true` (`platforms.telegram.extra.drop_pending_on_cold_boot` defaults to true; the
   prod logs show `Cold boot: dropping Telegram updates queued while offline` on every restart, including the
   0.22.2 rollout). A message sent during a deploy, an OOM restart or an upgrade is silently gone.
   With the relay, druzhok holds those updates and delivers them when the bot is back (at least once, see
   [Delivery guarantee](#delivery-guarantee)).
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
- records the `update_id` of every update it has *completed* in a per-bot receipt file under its home
  (`update_admission.py`, 24 h TTL) and drops a redelivered update whose id is in it, across restarts.

Druzhok adds to `Runtime.Hermes.env_vars/1`, only for bots in webhook mode:

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
- `telegram_updates`: `id`, `instance_id`, `update_id` (Telegram's), `payload` (raw JSON text), `received_at`,
  `acked_at` (the bot answered 2xx; null = pending), `attempts`, `last_error`, `dropped_reason`
  (null | `expired` | `rejected`). Unique index `(instance_id, update_id)`; index
  `(instance_id, acked_at, update_id)`.

**Ingress** — `DruzhokWebWeb.TelegramWebhookController`, route `POST /telegram/webhook/:bot` in its own
pipeline (no session, no CSRF; JSON body):

1. Look up the instance by name; unknown or not in webhook mode → 404 (visible in
   `getWebhookInfo.last_error_message`).
2. `Plug.Crypto.secure_compare` of `x-telegram-bot-api-secret-token` with the stored secret; mismatch → 401.
3. `INSERT … ON CONFLICT (instance_id, update_id) DO NOTHING` with the re-encoded body (Telegram redelivers
   when an ack is late; the unique index makes that a no-op).
4. 200 with an empty body, then `Relay.notify(instance_id)`. The handler never waits on the bot.

A 200 only after the row is committed is what makes the queue durable: if the insert fails, Telegram gets a
5xx and retries (it keeps updates up to 24 h).

**Relay** — `Druzhok.Telegram.Relay`: a `Registry` + `DynamicSupervisor`, one worker per webhook-mode bot,
started on boot for every such bot and on `notify/1`.

- **Order.** Delivers that bot's pending rows in `update_id` order, one in flight at a time. Telegram may
  push over parallel connections (hermes does not pass `max_connections`, PTB's default is 40), so arrival
  order and insert `id` can disagree with `update_id`, which is the order Telegram defines. (Telegram may
  restart update ids after a week of silence; any row that old has long expired, see housekeeping.)
- **Owner check, before every POST.** The worker reads `/proc/net/tcp` for the listener on
  `127.0.0.1:<port>` and delivers only if its uid is the bot's own (`bot-<name>`). Wrong owner → the row
  stays pending, the worker pauses, logs an error naming the owning uid, and retries in 30 s. The same read
  yields the listening socket's inode, which changes on every hermes restart (see
  [Delivery guarantee](#delivery-guarantee)). This is the in-process half of the port isolation below.
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
- **Pause around planned stops.** `BotManager.stop/1` and `restart/1` call `Relay.pause(instance_id)`
  before stopping hermes and `Relay.resume/1` after it is started, so nothing is handed to a bot that is
  draining (hermes's drain still answers 200 and then rejects or drops new work).
- **Housekeeping, hourly.** Delete acked rows older than 3 days. Pending rows older than 24 h get
  `dropped_reason = expired` and `acked_at = now`, one log line per bot — Telegram's own 24 h retention.

Item 6 hooks in here later: a worker whose bot is stopped asks `BotManager` to start it instead of only
backing off. Not in this spec.

### Delivery guarantee

**At least once, with hermes's receipts removing most duplicates.** PTB's 200 means "on an in-memory
queue", not "handled", so an ack alone cannot be the end of a row's life:

- **Planned stop** (deploy, `BotManager.restart`, upgrade): the relay is paused first, so nothing new
  reaches the draining bot.
- **Unplanned stop** (OOM, crash, `systemctl restart`, `druzhok-ctl restart`): the worker notices a new
  listener inode on its next owner check — before its next delivery, and every 30 s while it holds rows
  acked in the last 15 min. It then re-sends, in `update_id` order, every row acked in the 15 min before the
  restart. Hermes drops the ones it had completed (receipt file); the ones it had only queued are handled
  now.
- **Residual:** an update hermes was in the middle of handling when it died may be answered twice (its reply
  was sent, its receipt not yet written). That is the same at-least-once behaviour as polling, where
  `getUpdates` confirms an update before it is processed — and strictly better than today's cold-boot drop.

### Port isolation

Every bot can run arbitrary code as its own uid (the terminal tool), so the webhook port must be bound to
its bot at three layers — otherwise bot A can bind B's port while B restarts or sleeps, receive B's private
chats and B's secret, and then forge updates into B's queue as the operator.

1. **systemd** — `druzhok-ctl create` writes a per-bot drop-in,
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
   file (`TELEGRAM_WEBHOOK_PORT`), which druzhok writes before `create`/`start`.
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
- `ops/smoke.sh <bot>`: for webhook bots, `getWebhookInfo` must show our URL, `pending_update_count` 0–small,
  no `last_error_message` from the last 10 min; `telegram_updates` must have no pending row older than 60 s
  and the worker must not be paused; the listener on the bot's port must be owned by `bot-<name>`; the
  drop-in and the nft element must exist.
- Log line per delivery failure streak (first failure, pause, recovery), not per retry.

## Rollout

1. Deploy schema + code with every bot still `polling`. The `drop_pending_on_cold_boot: false` change ships
   now and reaches each bot on its next `BotManager.restart`; restart them one by one (this alone fixes the
   restart bug for polling bots).
2. nftables set + rule and the `druzhok-ctl` changes, loaded with the existing bootstrap path (reload
   refills `bot_uids` and `bot_webhook`).
3. Operator bot: `mix druzhok.telegram_mode igorhermes webhook`, `BotManager.restart`. Check:
   - hermes logs `Connected to Telegram (webhook mode)` and `Webhook server listening on 127.0.0.1:20009`;
     `getWebhookInfo.url` is ours;
   - a DM, a group message, a voice note and a photo are answered; web search and an LLM reply still work
     (outbound under `SocketBindDeny=any`);
   - as `bot-igorhermes`, binding another port (e.g. 20010) fails with EPERM;
   - **planned:** `BotManager.restart` mid-conversation, a message sent during the restart is answered after;
   - **unplanned:** `sudo systemctl kill -s KILL hermes@igorhermes` right after sending a message; the message
     is answered after systemd restarts the bot (replay), and an earlier, completed one is not answered again.
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
  `drop_pending_on_cold_boot`, `_validate_post`'s status codes and the receipt file in `update_admission.py`,
  like the other env vars and keys it checks.

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
  acked rows are not resent after a worker restart unless the listener inode changed, then only the last
  15 min are; pause/resume around `BotManager.restart`; expiry and pruning.
- Owner check: a parsed `/proc/net/tcp` fixture with the port owned by another uid → no POST, worker paused.
- `Runtime.Hermes`: webhook vars present only in webhook mode, host is 127.0.0.1, port = 20000 + id, URL uses
  `PHX_HOST`; `drop_pending_on_cold_boot: false` written for both modes; id ≥ 1000 refused.
- `druzhok-ctl` (shell test or bats): `create` writes the drop-in and the `uid . port` element from the env
  file; `destroy` removes both.
- Mode task: refuses to leave webhook mode with pending rows; generates the secret once.
