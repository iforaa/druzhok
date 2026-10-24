# Bot panel: the cabinet moves to druzhok

Status: draft, 2026-10-24. Follows ruoc-gateway
`docs/superpowers/specs/2026-10-24-telegram-mini-app-design.md` (the bot cabinet, live as ruoc `cc24742`,
druzhok `7c6fbee`).

## Why

The cabinet a bot's owner opens from «Кабинет» shows only the bot's ruoc account: plan, balance,
payment. The owner wants it to be the control panel of their hermes bot: its state, its settings, its
files. Those live in druzhok, not ruoc. A panel served by ruoc would have to forward almost every call to
druzhok; druzhok also holds the bot token, so it can check Telegram's init data the first-party way.

Decision (operator, 2026-10-24): **druzhok serves the Mini App and the panel; billing stays in ruoc** and
the page calls ruoc's existing `/tg/api/*` for it. ruoc-mobile is out of scope.

## Goals (v1)

1. «Кабинет» opens `https://<PHX_HOST>/app/?bot=<bot_id>`, a page druzhok serves.
2. Three tabs: **Бот** (state and settings), **Файлы** (the bot's files), **Счёт** (today's cabinet screens).
3. Бот and Файлы are **read only**. Nothing in v1 changes a bot.
4. Счёт behaves exactly as today, calling ruoc's `/tg/api/*` cross-origin.
5. Opening the panel never wakes a sleeping bot: it reads the row and the disk only.

## Non-goals (v1)

- Editing settings, SOUL.md, memory or jobs; clearing history. (v2; writes go through `BotSettings.update/2`
  and hermes's own CLI via `druzhok-ctl exec`, never by writing hermes's locked files.)
- Conversations (`state.db`, `sessions/`): group chats carry other people's messages.
- Mnemosyne contents, uploads, logs, `config.yaml`, `auth.json`, `.env`.
- ruoc-mobile.
- Any change to ruoc's billing logic, the binding (`PUT /partner/accounts/{id}/telegram`) or the
  out-of-money rule.

## Shape

```
Telegram ──«Кабинет»──▶ https://druzhok.oldey.dev/app/?bot=<bot_id>       (druzhok, Phoenix)
                          ├─ /app/api/*            → druzhok: init data checked with the bot token,
                          │                           owner = instances.owner_telegram_id, read-only
                          └─ https://oldey.dev/tg/api/*  → ruoc: billing, unchanged handlers,
                                                      plus CORS for druzhok's origin
```

The same `initData` string authenticates both: Telegram signs it with the bot token (druzhok checks the
HMAC) and with its Ed25519 key (ruoc checks that, as now). The page sends `Authorization: tma <initData>`
and `X-Telegram-Bot: <bot_id>` to both.

## Druzhok

### Routes

All under `PHX_HOST` only. `Plugs.BotSite` already passes that host through; no bot subdomain can reach
`/app`.

| Route | What |
|---|---|
| `GET /app/` | the page (`index.html`) |
| `GET /app/assets/*` | the bundle (`Plug.Static`, immutable cache) |
| `GET /app/api/bot` | state and settings |
| `GET /app/api/files` | the files index |
| `GET /app/api/files/{soul,memory,user}` | one Markdown file |
| `GET /app/api/jobs` | scheduled jobs, parsed |
| `GET /app/api/skills` | the bot's own skills |
| `GET /app/api/skills/:category/:name` | one skill's `SKILL.md` |
| `GET /app/api/site` | the website's file tree |

`/app/index.html` and any other path under `/app/` that is not a bundle file → 404 (one address per page).

### Page headers

```
Content-Security-Policy: default-src 'none'; script-src 'self' https://telegram.org;
  style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self' <RUOC_SITE_URL origin>;
  frame-ancestors https://web.telegram.org; base-uri 'none'; form-action 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
```

Same reasoning as ruoc's page (Telegram's script, Telegram Web's frame and injected style). `connect-src`
adds ruoc's public origin for the Счёт tab. API responses carry `Cache-Control: no-store`.

New setting: `RUOC_SITE_URL` (env or settings row, default `https://oldey.dev`), ruoc's public origin, as
opposed to `RUOC_URL`, which may be internal. `GET /app/api/bot` returns it as `billing_url` so the page
does not hardcode it.

### Authentication: `DruzhokWebWeb.Plugs.PanelAuth`

On every `/app/api/*` request, in this order:

1. **Rate limit** per client IP (the last `X-Forwarded-For` hop, which Caddy sets; druzhok listens only
   behind Caddy):
   60 requests a minute, ETS counter, 429 `rate_limited`.
2. Parse `Authorization: tma <initData>` and `X-Telegram-Bot` (1–20 digits). Missing or malformed → 401
   `init_invalid`.
3. **Find the bot**: the instance, not delete-requested, whose `Instance.telegram_bot_id/1` equals the header.
   None → 404 `not_found`. (A scan of the instances table; a few dozen rows. A `telegram_bot_id` column is
   a later optimisation, not v1.)
4. **Check init data** (Telegram's first-party scheme): `secret = HMAC_SHA256(key="WebAppData", bot_token)`;
   `data_check_string` = every `key=value` pair except `hash`, sorted by key, joined by `\n`, values URL-
   decoded; `hash` must equal `hex(HMAC_SHA256(secret, data_check_string))`, compared in constant time.
   `signature` stays in the string (Telegram's rule for the HMAC check excludes only `hash`). Mismatch →
   401 `init_invalid`.
5. **Freshness**: `auth_date` no older than `PANEL_INIT_MAX_AGE` (default 24 h; v1 is read only) and not
   more than 60 s in the future. Else 401 `init_stale` («закройте и откройте кабинет снова»).
6. **Owner**: `user.id` from the init data must equal `instances.owner_telegram_id`. Else 403 `not_owner`.
7. **Cabinet off**: `cabinet_off` true → 403 `cabinet_off`.

The token never leaves druzhok; the handler gets the instance.

### `GET /app/api/bot`

```json
{
  "name": "igorhermes", "bot_id": 8437439808, "username": "druzhokvasabot",
  "state": "awake" | "asleep" | "stopped" | "starting" | "error",
  "started_at": "…", "start_error": "…" | null,
  "settings": {
    "model": "ruoc-deepseek-flash", "language": "ru", "timezone": "Europe/Moscow",
    "mention_only": true, "trigger_name": "Вася",
    "sleep_enabled": true, "sleep_idle_minutes": 30,
    "image_gen_enabled": true, "image_gen_model": null,
    "website_hosting_enabled": true, "site_url": "https://igorhermes.oldey.dev",
    "memory_provider": "mnemosyne", "group_shared_memory": false
  },
  "access": { "allowed_chats": 3, "allowed_users": 2 },
  "billing_url": "https://oldey.dev"
}
```

- Built from `BotSettings.show/1` with an explicit allowlist: no secret, no `ruoc_account_id`, no
  `owner_telegram_id`, no lifecycle sequence numbers.
- `state` maps `Lifecycle.shown_status/2` plus `sleeping` to the five words above.
- `start_error` is cut to 300 characters with absolute paths under the data root replaced by `…`.
- `username` comes from a cached `getMe` (per bot, 24 h, in the `Druzhok.Cabinet` process or a small
  cache); null when Telegram does not answer. It is cosmetic.
- `access` gives counts only: the ids are other people's.

### Files: `Druzhok.TenantFiles`

The safe walk moves out of `Plugs.BotSite` into `Druzhok.TenantFiles` and both use it:
`lstat` every component below the tenant dir, no symlink anywhere, the leaf a regular file, open, then
re-walk and compare the descriptor's inode and device. Segment rules stay (`""`, `.`, `..`, leading `.` or
`_`, `/`, NUL refused).

The panel reads only these, relative to `/data/tenants/<name>`:

| What | Path | Limit |
|---|---|---|
| Character | `SOUL.md` | 256 KiB |
| Memory | `memories/MEMORY.md` | 256 KiB |
| About the owner | `memories/USER.md` | 256 KiB |
| Jobs | `cron/jobs.json` | 1 MiB |
| Own skills | `skills/<category>/<name>/SKILL.md`, not listed in `skills/.bundled_manifest` | 256 KiB each, 200 skills |
| Website | `workspace/sites/<name>/**` (tree only) | 2000 entries, depth 8 |

Anything else is unreachable: the routes name fixed files, and the two parametrised routes
(`skills/:category/:name`) pass segment validation and must be in the own-skills list just computed.
Reading never takes hermes's `fcntl` locks; a file caught mid-write is shown as it is, and the next open
reads the new one (hermes writes these atomically via temp file + rename, so a torn read is a guess, not
seen). Over the limit → the first N bytes plus `"truncated": true`. Non-UTF-8 → 422 `not_text`.

### `GET /app/api/files`

```json
{
  "soul":   { "size": 2140, "modified_at": "…" } | null,
  "memory": { … } | null,
  "user":   { … } | null,
  "jobs":   { "count": 3 },
  "skills": { "own": 2, "bundled": 74 },
  "site":   { "files": 12, "url": "https://igorhermes.oldey.dev" } | null
}
```

`GET /app/api/files/soul` (and `memory`, `user`) → `{"text": "…", "modified_at": "…", "truncated": false}`.

### `GET /app/api/jobs`

From `cron/jobs.json`, each job: `name`, `prompt`, `schedule_display`, `state` (`scheduled`/`paused`/…),
`enabled`, `next_run_at`, `last_run_at`, `last_status`, `repeat` (`times`, `completed`). Unknown fields are
dropped; a file that does not parse → `{"jobs": [], "error": "unreadable"}`. Delivery targets (`deliver`,
chat ids) are not shown.

### `GET /app/api/skills`, `GET /app/api/skills/:category/:name`

Own skills only: the name, category and `description` from the YAML front matter of `SKILL.md` (parsed
leniently: the `---` block, `name:`/`description:` lines; no YAML library). The bundled count is the
manifest's line count. The single-skill route returns `{"text": …}` of `SKILL.md` only, never the
skill's `references/`, `templates/` or `assets/`.

### `GET /app/api/site`

The tree of `workspace/sites/<name>/` as `[{path, size}]` (dot and `_` entries skipped, as BotSite does),
plus `url`. Files open on the live site in the system browser (`openLink`); the panel does not proxy them.
`website_hosting_enabled` false → `null`.

### `Druzhok.Cabinet` changes

- The button's URL is druzhok's panel URL, `https://<PHX_HOST>/app/?bot=<bot_id>`, no longer ruoc's
  `mini_app_url`. ruoc's reply is still required (it proves the binding) but its URL is ignored.
- `cabinet_url` stores the panel URL. A bot whose `cabinet_url` differs from the panel URL counts as
  "button not set": the next start, wake, owner message or `bind-cabinet` sets the button again without a
  ruoc call. That is the whole migration; no data step.
- The out-of-money notice opens `…/app/?bot=<bot_id>&tab=billing`.
- No `PHX_HOST` → the cabinet stays as it is today (ruoc's URL), with a warning in the log. Dev and test
  have no public host.

### The page

- Source moves from ruoc `web/miniapp/` to `apps/druzhok_web/assets/app/` (Vite, React, TypeScript, the
  same `telegram.ts`, `api.ts`, styles). Build output `apps/druzhok_web/priv/static/app/`, committed, as
  ruoc commits `web/dist`. `ops/build-app.sh` builds it; the deploy steps in CLAUDE.md gain one line, and a
  test fails when the committed `index.html` does not reference the committed bundle.
- `api.ts` gets two bases: `/app/api/` for the panel, `<billing_url>/tg/api/` for billing.
- Tabs at the bottom; `?tab=billing` opens Счёт. Text in the bot's `language` (ru, en; ru default).
- Markdown files render as Markdown (`marked`, HTML in the source escaped, links opened with `openLink`).
- Every error from either API shows its message and, for `init_stale`, the reopen hint.

## ruoc-gateway

1. **CORS for `/tg/api/*`**, from a new allowlist `TG_PANEL_ORIGINS` (default empty; prod
   `https://druzhok.oldey.dev`). It must be decided in `withCORS`, which answers every `OPTIONS` before any
   route runs: for a path under `/tg/api/`, the allowed origins are `TG_PANEL_ORIGINS` (not
   `ALLOWED_ORIGINS`) and the allowed headers add `X-Telegram-Bot`. No `Access-Control-Allow-Credentials`:
   the API uses no cookie. Other paths keep today's behaviour exactly.
2. Nothing else. `/tg/`, `/tg/paid`, `/tg/unpaid` stay: the bank returns the owner to `/tg/paid`, and the
   old page keeps working for any button not yet moved. Removing `/tg/` is a later change once every
   bot's `cabinet_url` is druzhok's.

## Failure behaviour

| Case | Result |
|---|---|
| ruoc down | Бот and Файлы work; Счёт shows ruoc's error |
| druzhok down | nothing opens (the page is druzhok's) — accepted; druzhok down means the bots are down too |
| bot asleep | everything works; nothing wakes it |
| owner changed | old owner gets 403 `not_owner`; `Druzhok.Cabinet` already resets their button |
| init data from another bot | HMAC fails with this bot's token → 401 |

## Tests

- Druzhok:
  - init data: a vector signed with a test token passes; a changed field, a wrong token, a missing hash,
    a stale or future `auth_date` fail;
  - `PanelAuth`: unknown bot, non-owner, `cabinet_off`, deleted bot, rate limit;
  - `TenantFiles`: a symlinked `SOUL.md`, a symlinked `memories/`, a symlink inside a skill path, a swap
    between walk and open (the BotSite tests move with the code), size truncation, non-UTF-8;
  - `/app/api/bot`: no secret or account id in the body (assert on the encoded JSON);
  - skills: bundled ones excluded, a name not in the own list → 404;
  - `Cabinet`: a bot with ruoc's URL in `cabinet_url` gets the button reset to the panel URL with no ruoc
    call; no `PHX_HOST` keeps ruoc's URL.
- ruoc: preflight and simple request on `/tg/api/me` from the allowed origin get the headers incl.
  `X-Telegram-Bot`; another origin gets none; `/v1/*` behaviour unchanged.

## Rollout

1. ruoc: `TG_PANEL_ORIGINS` code, deploy, set `TG_PANEL_ORIGINS=https://druzhok.oldey.dev` in
   `/etc/ruoc/ruoc.env` (backup first), restart.
2. druzhok: merge, deploy. Buttons still point at ruoc until something triggers the cabinet.
3. `sudo ops/druzhok bind-cabinet igorhermes`; check Бот, Файлы, Счёт and one payment in Telegram Web and
   on the phone.
4. Other bots move on their next start or wake. `bind-cabinet` (all) moves them at once.
5. Later: remove ruoc's `/tg/` page.

## Open questions

- `sleep_idle_minutes` is a global setting today; the panel shows the global value. Fine for v1?
- Show the owner the ids in the allowlists, or counts only (this draft: counts)?
