# Telegram webhook relay

Status: draft, 2026-10-20. Branch `telegram-webhook-relay`. Block A item 5; item 6 (sleep/wake) builds on it.

## Goal

Telegram delivers every bot's updates to druzhok, which stores them and relays them to the bot. Bots stop
long-polling `getUpdates`.

What this buys:

1. **No lost messages on restart.** Today every bot start is a hermes *cold boot*, which calls Telegram with
   `drop_pending_updates=true` (`platforms.telegram.extra.drop_pending_on_cold_boot` defaults to true; the
   prod logs show `Cold boot: dropping Telegram updates queued while offline` on every restart, including the
   0.22.2 rollout). A message sent during a deploy, an OOM restart or an upgrade is silently gone.
   With the relay, druzhok holds those updates and delivers them when the bot is back.
2. **A queue druzhok owns.** This is the precondition for item 6: a stopped bot's messages wait in druzhok,
   which can then start the bot and deliver them. Without it, a sleeping bot either keeps a poller running
   (no RAM saved) or loses messages.
3. **Cheaper idle bots.** No long-poll socket per bot (15 Telegram connections today), no polling
   heartbeat / `getWebhookInfo` probes, no CLOSE-WAIT wedge recovery. Hermes runs those only in polling mode.

Non-goals: sleep/wake itself (item 6), moving the superbot (`Druzhok.ManagerBot`, Elixir, always on) off
polling, multi-host routing (Block B), a Bot API facade.

## How it works

```
Telegram ──HTTPS──▶ Caddy (druzhok.oldey.dev:443) ──▶ Phoenix  POST /telegram/webhook/:bot
                                                        │ check secret header, INSERT update, 200
                                                        ▼
                                              telegram_updates (SQLite)
                                                        │ Druzhok.Telegram.Relay, one worker per bot, FIFO
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
- rejects requests whose `X-Telegram-Bot-Api-Secret-Token` does not match;
- on disconnect does **not** delete the webhook (only polling mode calls `deleteWebhook`, at start), so
  updates keep flowing to druzhok while the bot is stopped — exactly what item 6 needs.

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

Port: `20000 + id` is unique per row, stable, and fits under the 1024-wide nftables range below (ids are 9–26
today). Nothing on the box listens in 20000–20999 (`ss -ltn` 2026-10-20: 22, 53, 80, 443, 2019, 3306, 4000,
5432, 8787, 9091, one ephemeral beam port). `id >= 1000` refuses webhook mode with a clear error.

### Druzhok side

**Schema** (one migration):

- `instances.telegram_mode` — `"polling"` (default) | `"webhook"`. Per bot, so rollout and rollback are one bot
  at a time.
- `instances.telegram_webhook_secret` — generated on the first switch to webhook, kept afterwards.
- `telegram_updates`: `id`, `instance_id`, `update_id` (Telegram's), `payload` (raw JSON text), `received_at`,
  `delivered_at` (null = pending), `attempts`, `last_error`. Unique index `(instance_id, update_id)`; index
  `(instance_id, delivered_at, id)`.

**Ingress** — `DruzhokWebWeb.TelegramWebhookController`, route `POST /telegram/webhook/:bot` in its own
pipeline (no session, no CSRF, no auth plug; JSON body):

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

- Delivers that bot's pending rows in `id` order, one in flight at a time (ordering per bot is what hermes
  expects; PTB's handler acks as soon as the update is on its queue, so this is not a throughput limit).
- `POST http://127.0.0.1:<port>/telegram/webhook/<name>` with the secret header and the payload, 10 s timeout
  (Finch, existing pool).
- 2xx → set `delivered_at`. Connection refused / timeout / 5xx → `attempts += 1`, `last_error`, back off
  1 s → 2 s → … → 30 s cap and retry the same row (the bot is restarting; the head of the line waits, order
  is kept). 4xx other than 429 → the bot rejected it (secret mismatch after a rotation, malformed) → log,
  mark delivered with `last_error`, move on, so one bad row cannot block a bot forever.
- Housekeeping, hourly: delete delivered rows older than 3 days; mark pending rows older than 24 h as
  dropped (`delivered_at` set, `last_error = "expired"`) and log one line per bot — matches Telegram's own
  24 h retention.

Item 6 hooks in here later: a worker whose bot is stopped asks `BotManager` to start it instead of only
backing off. Not in this spec.

**Egress rule** (`ops/nftables-druzhok.nft`): the bot's PTB server must be able to *answer* druzhok on
loopback. Today every bot-uid packet that is not to the proxy/DNS/Telegram is dropped, which includes the
SYN-ACK of an accepted connection. Add, before the final drop:

```
# Webhook relay: replies from a bot's PTB server (127.0.0.1:20000+id) to druzhok.
ip daddr 127.0.0.1 tcp sport 20000-20999 ct direction reply accept
```

`ct direction reply` only matches packets of a connection someone else opened, so a bot cannot use it to
reach other local services by binding its own source port into the range. The listener is reachable by
every local user, which is why the secret is required (hermes refuses to start without one).

**Public reachability**: `druzhok.oldey.dev` resolves straight to 195.49.213.8 (no Cloudflare proxy) and
Caddy already serves it on 443, one of the four ports Telegram allows. No Caddy change. Telegram must accept
Caddy's certificate (Let's Encrypt via DNS-01, fine).

### Superbot

Unchanged, keeps polling. It is one Elixir process, has no RAM to save and never sleeps.

## Visibility

- Dashboard settings tab: mode, pending count, oldest pending age, last error. Read-only; switching mode is
  a `mix druzhok.telegram_mode <name> webhook|polling` task plus `BotManager.restart`, not a UI control
  (UI freeze, item 7).
- `ops/smoke.sh <bot>`: for webhook bots, `getWebhookInfo` must show our URL, `pending_update_count` 0–small,
  no `last_error_message` from the last 10 min; `telegram_updates` must have no pending row older than 60 s.
- Log line per delivery failure streak (first failure and recovery), not per retry.

## Rollout

1. Deploy schema + code with every bot still `polling`. The `drop_pending_on_cold_boot: false` change ships
   now and reaches each bot on its next `BotManager.restart`; restart them one by one (this alone fixes the
   restart bug for polling bots).
2. nftables rule, loaded with the existing bootstrap path (reload refills `bot_uids`).
3. Operator bot: `mix druzhok.telegram_mode igorhermes webhook`, `BotManager.restart`. Check: hermes logs
   `Connected to Telegram (webhook mode)` and `Webhook server listening on 127.0.0.1:20009`;
   `getWebhookInfo.url` is ours; a DM, a group message, a voice note and a photo are answered; then
   `sudo druzhok-ctl restart` mid-conversation and confirm a message sent during the restart is answered
   after it.
4. One day on the operator bot, then the other bots one at a time with `ops/smoke.sh`.

## Rollback

Per bot: set `polling`, `BotManager.restart`. Hermes's polling start calls `deleteWebhook` (required to
succeed on cold boot) and resumes `getUpdates`. Rows still pending in druzhok for that bot are not
deliverable once it polls; the mode task refuses to switch back while any are pending unless `--force`
(which reports how many are dropped).

Full: all bots to polling, then revert the code. The schema additions are inert.

## Risks

- **druzhok becomes a single point for inbound messages.** It already is for every LLM call, so a druzhok
  outage already makes bots mute; with the relay, messages sent during it are delivered afterwards instead
  of answered late by a bot that cannot reach the model anyway. Telegram buffers 24 h while druzhok is down.
- **Deploy restarts of druzhok** (~20 s) delay delivery but lose nothing (Telegram retries, the queue is in
  SQLite).
- **SQLite write load**: one insert + one update per Telegram update; at today's volume (tens per hour) this
  is negligible next to `usage_logs`.
- **One poller per token** still holds: a bot running in polling mode anywhere else calls `deleteWebhook`
  and silently takes the token's updates. `getWebhookInfo` in smoke catches it.
- **Secret rotation**: rotating `telegram_webhook_secret` takes a restart of that bot (hermes re-registers);
  rows in flight get 401 from the bot and are marked failed — acceptable, rotation is manual and rare.
- **Hermes upgrades**: the update-hermes skill must grep `TELEGRAM_WEBHOOK_URL|_SECRET|_PORT|_HOST` and
  `drop_pending_on_cold_boot` in the adapter like the other env vars it checks.

## Alternatives considered

- **Druzhok as a Bot API facade** (`platforms.telegram.extra.base_url` → druzhok; druzhok serves
  `getUpdates` from its queue and proxies every other method). Bots would keep polling, but druzhok would sit
  in the path of every `sendMessage`, upload and file download — the multipart class of bugs the
  "no HTTP_PROXY" rule exists for — for no gain over native webhook mode.
- **druzhok calls `setWebhook` itself and bots stay unaware.** Hermes in polling mode deletes any webhook at
  start, so this needs webhook mode on the bot side anyway.
- **Unix socket instead of a TCP port** (PTB supports `unix=`). Cleaner isolation, but hermes does not expose
  it, so it costs a fork patch; the `ct direction reply` rule plus the secret is enough.

## Tests

- Controller: valid secret → row + 200; wrong/missing secret → 401, no row; unknown bot / polling bot → 404;
  duplicate `update_id` → 200, still one row; insert failure → 5xx.
- Relay (Bypass as the bot): FIFO order; head-of-line retry with backoff on refused/5xx, then delivery;
  4xx marks failed and moves on; delivered rows are not resent after a worker restart; expiry and pruning.
- `Runtime.Hermes`: webhook vars present only in webhook mode, host is 127.0.0.1, port = 20000 + id, URL uses
  `PHX_HOST`; `drop_pending_on_cold_boot: false` written for both modes; id ≥ 1000 refused.
- Mode task: refuses to leave webhook mode with pending rows; generates the secret once.
