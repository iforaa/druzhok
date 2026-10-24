# Bot panel: the cabinet moves to druzhok

Status: draft r2, 2026-10-24. Follows ruoc-gateway
`docs/superpowers/specs/2026-10-24-telegram-mini-app-design.md` (the bot cabinet, live as ruoc `cc24742`,
druzhok `7c6fbee`).

## Why

The cabinet a bot's owner opens from «Кабинет» shows only the bot's ruoc account: plan, balance,
payment. The owner wants it to be the control panel of their hermes bot: its state, its settings, its
files. Those live in druzhok, not ruoc. A panel served by ruoc would have to forward almost every call to
druzhok.

Decision (operator, 2026-10-24): **druzhok serves the Mini App and the panel; billing stays in ruoc** and
the page calls ruoc's existing `/tg/api/*` for it. ruoc-mobile is out of scope.

## Goals (v1)

1. «Кабинет» opens `https://<PHX_HOST>/app/?bot=<bot_id>`, a page druzhok serves.
2. Three tabs: **Бот** (state and settings), **Файлы** (the bot's files), **Счёт** (today's cabinet screens).
3. Бот and Файлы are **read only**. Nothing in v1 changes a bot.
4. Счёт behaves exactly as today, calling ruoc's `/tg/api/*` cross-origin.
5. Opening the panel never wakes a sleeping bot: it reads the instance row, the disk, and the unit's state
   (one `BotManager.status/1` call per `GET /app/api/bot`, which in prod runs `sudo druzhok-ctl status`).

## Non-goals (v1)

- Editing settings, SOUL.md, memory or jobs; clearing history. (v2; writes would go through
  `BotSettings.update/2` and hermes's own CLI via `druzhok-ctl exec`, never by writing hermes's locked
  files. The authentication below is designed so that a bot cannot pass it, which v2 relies on.)
- Conversations (`state.db`, `sessions/`): group chats carry other people's messages.
- Mnemosyne contents, uploads, logs, `config.yaml`, `auth.json`, `.env`.
- Links to the bot's live website: `*.oldey.dev` reaches ruoc, not druzhok's BotSite (`ops/Caddyfile`;
  bot sites are dark). v1 shows the website's file tree only. Routing bot subdomains is its own change.
- ruoc-mobile.
- Any change to ruoc's billing logic, the binding (`PUT /partner/accounts/{id}/telegram`) or the
  out-of-money rule.

## Shape

```
Telegram ──«Кабинет»──▶ https://druzhok.oldey.dev/app/?bot=<bot_id>       (Caddy → druzhok :4000)
                          ├─ /app/api/*            → druzhok: edge header, Telegram's Ed25519 signature
                          │                           + bot-token HMAC, owner = instances.owner_telegram_id
                          └─ https://oldey.dev/tg/api/*  → ruoc: billing, unchanged handlers,
                                                      plus CORS for druzhok's origin
```

The same `initData` string authenticates both. The page sends `Authorization: tma <initData>` and
`X-Telegram-Bot: <bot_id>` to both.

## Druzhok

### Who can reach `/app`

druzhok listens on `127.0.0.1:4000`, and **bot processes reach that port directly** (the LLM proxy;
`ops/nftables-druzhok.nft`). A bot can send any `Host` and any `X-Forwarded-For`. So `/app` (page and API)
requires an **edge header** only Caddy sets:

- Caddy's `druzhok.oldey.dev` block: `header_up X-Druzhok-Edge {env.DRUZHOK_EDGE_SECRET}` (sets, so a
  client-sent value is overwritten). The secret lives in `/etc/caddy/env` and in `/etc/druzhok/druzhok.env`
  as `DRUZHOK_EDGE_SECRET`, never a settings row. The prod Caddyfile drifts from the repo: the rollout
  patches that one block and backs the file up first.
- druzhok's `Plugs.Edge` on the `/app` scope: constant-time compare; mismatch or missing → 404 (the route
  does not exist for anyone else). No `DRUZHOK_EDGE_SECRET` configured → `/app` is closed (404), as
  `/internal/fetch` is without its secret.
- With the edge header proven, `X-Forwarded-For` is Caddy's and its last hop is the client IP.

`Plugs.BotSite` runs before the router and halts on `<bot>.oldey.dev`, so a bot subdomain never reaches
`/app` either way.

### Routes

| Route | What |
|---|---|
| `GET /app/` | the page (`index.html`) |
| `GET /app/assets/*` | the bundle (immutable cache) |
| `GET /app/api/bot` | state and settings |
| `GET /app/api/files` | the files index |
| `GET /app/api/files/{soul,memory,user}` | one Markdown file |
| `GET /app/api/jobs` | scheduled jobs |
| `GET /app/api/skills` | the bot's own skills |
| `GET /app/api/skills/:name` | an uncategorised own skill's `SKILL.md` |
| `GET /app/api/skills/:category/:name` | a categorised own skill's `SKILL.md` |
| `GET /app/api/site` | the website's file tree |

All of `/app` sits behind `Plugs.Edge`. The bundle is served by a `Plug.Static` inside the `/app` scope
(not in the endpoint, so the edge check covers it). `/app/index.html` and any other path under `/app/`
that is not a bundle file → 404.

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
opposed to `RUOC_URL`, which may be internal. `GET /app/api/bot` returns it as `billing_url`.

### Authentication: `DruzhokWebWeb.Plugs.PanelAuth`

After `Plugs.Edge`, on every `/app/api/*` request, in this order:

1. **Rate limit** per client IP (last `X-Forwarded-For` hop, trusted because of the edge header): 60
   requests a minute, ETS counter, 429 `rate_limited`.
2. Parse `Authorization: tma <initData>` and `X-Telegram-Bot` (1–20 digits). Missing or malformed → 401
   `init_invalid`.
3. **Find the bot**: the instance, `delete_requested` false, whose `Instance.telegram_bot_id/1` equals the
   header. None → 404 `not_found`. (A scan of the instances table; a few dozen rows.)
4. **Telegram's Ed25519 signature** (the third-party scheme, as ruoc's `telegram_init.go`): the
   data-check string is `"<bot_id>:WebAppData\n"` followed by every `key=value` pair except `hash` and
   `signature`, sorted by key, values URL-decoded, joined by `\n`; `signature` is base64url (unpadded) and
   must verify with Telegram's production public key
   `e7bf03a2fa4602af4580703d88dda5bb59f32ed8b02a56c187fe7d34caed242d`
   (`:crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])`). Missing or invalid → 401 `init_invalid`.
   **This is the check a bot cannot pass:** every bot holds its own token (`TELEGRAM_BOT_TOKEN` in its env,
   `Runtime.Hermes.env_vars/1`), so a token HMAC alone could be minted by the bot itself for its owner's id.
   Only Telegram holds the Ed25519 private key.
5. **Bot-token HMAC** (the first-party scheme), as a second check: `secret = HMAC_SHA256(key="WebAppData",
   msg=bot_token)`; `data_check_string` = every pair except `hash`, sorted, URL-decoded, joined by `\n`
   (`signature` included); `hash` must equal the hex HMAC, constant-time. It binds the data to this bot's
   current token. Mismatch → 401 `init_invalid`.
6. **Freshness**: `auth_date` no older than `PANEL_INIT_MAX_AGE` (default 24 h; v1 is read only) and not
   more than 60 s in the future. Else 401 `init_stale`.
7. **Owner**: `user.id` from the init data must equal `instances.owner_telegram_id`. Else 403 `not_owner`.
8. **Cabinet off**: `cabinet_off` true → 403 `cabinet_off`.

The handler gets the instance. No response ever carries the token.

### `GET /app/api/bot`

```json
{
  "name": "igorhermes", "bot_id": 8437439808, "username": "druzhokvasabot",
  "state": "awake" | "asleep" | "starting" | "stopped" | "error",
  "started_at": "…", "start_error": "…" | null,
  "settings": {
    "model": "ruoc-deepseek-flash", "language": "ru", "timezone": "Europe/Moscow",
    "mention_only": true, "trigger_name": "Вася",
    "sleep_enabled": true, "sleep_idle_minutes": 30,
    "image_gen_enabled": true, "image_gen_model": null,
    "website_hosting_enabled": true,
    "memory_provider": "mnemosyne", "group_shared_memory": false
  },
  "access": { "allowed_chats": 3, "allowed_users": 2 },
  "billing_url": "https://oldey.dev"
}
```

- Built from the `Instance` row with an explicit allowlist of the fields above, not from
  `BotSettings.show/1` (whose output carries masked secrets and the account id). `sleep_idle_minutes` is the
  global setting (`Settings`), the same for every bot.
- `state` from `Lifecycle.shown_status(inst, BotManager.status(name))`:

  first matching row wins:

  | `shown_status` | `inst.active` | `state` |
  |---|---|---|
  | `active` | any | `awake` |
  | `sleeping` | any | `asleep` |
  | `activating`, `waking`, `restarting` | any | `starting` |
  | `stopping`, `deleting` | any | `stopped` |
  | `inactive`, `failed` | false | `stopped` |
  | `inactive`, `failed` | true (start backoff) | `error` |
  | anything else (`unknown`, a new word) | any | `error` |
- `start_error` is cut to 300 characters with absolute paths under the data root replaced by `…`.
- `username` from `getMe`, cached in an ETS table owned by a small supervised process for 24 h. The
  request reads ETS directly; on a miss it calls `getMe` with a 2 s timeout, and on failure returns null.
  It never goes through `Druzhok.Cabinet` (casts only by contract).
- `access` gives counts only: the ids are other people's.

### Files: `Druzhok.TenantFiles`

The safe walk moves out of `Plugs.BotSite` into `Druzhok.TenantFiles`; BotSite and the panel both use it.

**Opening a file** (as BotSite does today): `lstat` every component below the tenant dir; every
intermediate a real directory, the leaf a regular file, no symlink anywhere; open; re-walk and compare the
descriptor's inode and device. Bytes and `stat` figures come from the verified descriptor
(`:file.read_file_info(fd)`), never from a second lookup by name.

**Listing a directory** (website tree, skills discovery): the root itself is `lstat`ed and must be a real
directory (a symlinked root → treated as absent). Entries are read with `File.ls`, each one `lstat`ed: real
directories are descended into, regular files are reported, **symlinks and everything else are skipped and
never reported**. Any file whose contents a listing needs (a skill's front matter) is read through the
verified open above.

**Segment rules** (`""`, `.`, `..`, leading `.` or `_`, `/`, NUL refused) apply to **segments that come
from a request** (the skills routes). Fixed paths the code names itself (`skills/.bundled_manifest`) go
through the same lstat/inode walk without the segment rules.

The panel reads only these, relative to `/data/tenants/<name>`:

| What | Path | Limit |
|---|---|---|
| Character | `SOUL.md` | 256 KiB |
| Memory | `memories/MEMORY.md` | 256 KiB |
| About the owner | `memories/USER.md` | 256 KiB |
| Jobs | `cron/jobs.json` | 1 MiB |
| Bundled skills list | `skills/.bundled_manifest` | 256 KiB |
| Own skills | `skills/<name>/SKILL.md` and `skills/<category>/<name>/SKILL.md` | 256 KiB each, 200 skills |
| Website | `workspace/sites/**` (tree only) | 2000 entries, depth 8 below `sites/` |

Reading never takes hermes's `fcntl` locks. Hermes writes these files by temp file + rename (a guess from
`memory_tool.py`/`jobs.py`; not proven), so a read sees either version.

**Text and limits:** read at most limit + 4 bytes. If the file is longer than the limit, cut at the limit
and then back to the last complete UTF-8 code point (drop up to 3 trailing continuation bytes), and set
`"truncated": true`. The UTF-8 check runs on the trimmed buffer, so a valid file never fails because of
the cut. Invalid UTF-8 inside the kept text → 422 `not_text`. JSON files (`jobs.json`) over their limit →
`{"jobs": [], "error": "too_large"}` rather than a cut.

### `GET /app/api/files`

```json
{
  "soul":   { "size": 2140, "modified_at": "…" } | null,
  "memory": { … } | null,
  "user":   { … } | null,
  "jobs":   { "count": 3 },
  "skills": { "own": 2, "bundled": 74 },
  "site":   { "files": 12, "sites": ["promo", "cv"] } | null
}
```

`GET /app/api/files/soul` (and `memory`, `user`) → `{"text": "…", "modified_at": "…", "truncated": false}`.

### `GET /app/api/jobs`

`cron/jobs.json`'s canonical shape is `{"jobs": [...]}`; a bare list is accepted too. Anything else, or a
parse failure → `{"jobs": [], "error": "unreadable"}`. Each job is shown the way hermes's own list shows it
(`cron/jobs.py` `_normalize_job_record`):

- `name`: stored `name` trimmed; if empty, the first 50 characters of `prompt`, else `skills[0]` (or
  `skill`), else `script`, else `id`, else «cron job».
- `schedule`: stored `schedule_display`; if empty, `schedule.display`, `.value`, `.expr` or `.run_at` (first
  non-empty), or `schedule` itself when it is a string; else «?».
- `state` (hermes's `effective_job_state`): stored `state` `completed` or `error` is kept; else when
  `enabled` (default true) is false → `paused` (or the stored state if it is non-empty and not paused);
  when `enabled` is true → `scheduled` if the stored state is `paused` or `paused_at` is set, else the stored
  state or `scheduled`.
- Also: `prompt`, `next_run_at`, `last_run_at`, `last_status`, `repeat` (`times`, `completed`).

Delivery targets (`deliver`, chat ids) are not shown.

### Skills

- **Discovery:** under `skills/`, every real directory one level down that holds a `SKILL.md` is an
  uncategorised skill (`skills/<name>/`); every real directory two levels down that holds one is a
  categorised skill (`skills/<category>/<name>/`). Dot and `_` entries are skipped. hermes allows both
  (`tools/skill_manager_tool.py`, the category is optional).
- **Bundled or own:** the skill's identifier is its front-matter `name:` (parsed leniently from the
  leading `---` block), else its directory name. It is bundled when that identifier equals the part before
  `:` of a line in `skills/.bundled_manifest` (v2 lines are `name:hash`, v1 lines a bare `name`). Own
  skills are the rest. The bundled count is the number of manifest names that still have a skill on disk
  (deleted bundled skills stay in the manifest).
- **Listing** returns own skills: `name`, `category` (or null), `description` from the front matter.
- **Opening:** `/app/api/skills/:name` or `/app/api/skills/:category/:name` → `{"text": …}` of that
  `SKILL.md` only (never its `references/`, `templates/`, `assets/`). The requested path must be one the
  own-skills discovery just returned; anything else → 404.

### `GET /app/api/site`

The tree of `workspace/sites/` (the root BotSite serves), as `[{site, path, size}]` grouped by top-level
directory (a bot can publish several sites; `AGENTS.md` tells it to use `sites/<имя>/`). `path` is relative
to `sites/`. Dot and `_` entries are skipped, as BotSite does. No URLs or links in v1 (see non-goals).
`website_hosting_enabled` false, or no `sites/` directory → `null`.

### `Druzhok.Cabinet` changes

With `PHX_HOST` set, the panel URL is `https://<PHX_HOST>/app/?bot=<bot_id>` and it replaces ruoc's
`mini_app_url` everywhere:

- `bind/2` writes the panel URL into `cabinet_url`. ruoc's reply is still required (it proves the binding);
  its URL is ignored.
- `bind_now/1`: the `:unchanged` branch also requires `cabinet_url == panel_url`; the `:button` branch
  (binding current, button or URL stale) writes `cabinet_url = panel_url` and sets the button to the panel
  URL, with no ruoc call.
- `button_moment?/2` is also true when `cabinet_url != panel_url`, so the owner's next private message
  moves a bot that is never restarted.
- The out-of-money notice opens `…/app/?bot=<bot_id>&tab=billing`.
- A failed `setChatMenuButton` leaves `cabinet_url` as it was, so the next trigger tries again; a success
  writes the panel URL, after which every check is `:unchanged` (no loop, no ruoc call).

No `PHX_HOST` (dev, test) → everything behaves as today, with ruoc's URL.

### The page

- Source moves from ruoc `web/miniapp/` to `apps/druzhok_web/assets/app/` (Vite, React, TypeScript, the
  same `telegram.ts`, `api.ts`, styles). Build output `apps/druzhok_web/priv/static/app/`, committed, as
  ruoc commits `web/dist`; `node_modules/` is gitignored and never rsynced. `ops/build-app.sh` builds it;
  the deploy steps in CLAUDE.md gain one line, and a test fails when the committed `index.html` references
  a bundle file that is not committed.
- `api.ts` gets two bases: `/app/api/` for the panel, `<billing_url>/tg/api/` for billing.
- Tabs at the bottom; `?tab=billing` opens Счёт. Text in the bot's `language` (ru, en; ru default).
- Markdown renders with `marked`, raw HTML in the source escaped; links open with `openLink`.
- Every error from either API shows its message and, for `init_stale`, the reopen hint.
- Payment works as today: checkout returns the bank's URL, the page opens it with `openLink` from a tap,
  the bank returns the owner to ruoc's `/tg/paid` / `/tg/unpaid`, and the Счёт tab polls
  `/tg/api/payments/{id}` on ruoc.

## ruoc-gateway

1. **CORS for `/tg/api/*`**, from a new allowlist `TG_PANEL_ORIGINS` (default empty; prod
   `https://druzhok.oldey.dev`). It is decided in `withCORS`, which answers every `OPTIONS` before any
   route runs: for a path under `/tg/api/`, the allowed origins are `TG_PANEL_ORIGINS` (not
   `ALLOWED_ORIGINS`), allowed methods `GET, POST, OPTIONS`, allowed headers
   `Content-Type, Authorization, X-Telegram-Bot`. No `Access-Control-Allow-Credentials`: the API uses no
   cookie. Paths outside `/tg/api/` keep today's behaviour exactly.
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
| init data from another bot | Ed25519 fails (bot id is in the signed string) → 401 |
| a bot forging init data with its token | Ed25519 fails → 401 |
| a bot calling `127.0.0.1:4000/app/…` | no edge header → 404 |

## Tests

- Druzhok:
  - init data: a vector signed with a test Ed25519 key (the verifier takes the public key as config, prod
    default above) and a test token passes; a valid token HMAC with a missing or wrong signature fails; a
    valid signature with a wrong HMAC fails; another bot id fails; a changed field, a stale or future
    `auth_date` fail;
  - `Plugs.Edge`: missing, wrong, and unconfigured secret → 404 for page, bundle and API;
  - `PanelAuth`: unknown bot, non-owner, `cabinet_off`, deleted bot, rate limit (keyed on the XFF hop);
  - `TenantFiles`: a symlinked `SOUL.md`, a symlinked `memories/`, a swap between walk and open (the
    BotSite tests move with the code); listings with a symlinked directory and a symlinked file inside
    `sites/` and inside `skills/` (skipped, not reported), a symlinked `sites/` root; a symlinked
    `.bundled_manifest`; truncation mid-Cyrillic returns valid text with `truncated: true`; invalid UTF-8
    → 422;
  - `/app/api/bot`: no secret, account id or owner id in the encoded JSON; the state table;
  - skills: uncategorised and categorised own skills listed and opened; a bundled one (by front-matter
    name) excluded; a path not in the own list → 404;
  - jobs: name/schedule/state derivations match the cases above; `{"jobs": …}` and bare list; garbage;
  - `Cabinet`: a bot bound on ruoc's URL with the button set moves to the panel URL on `bind_now` (no ruoc
    call) and on the owner's message (`button_moment?/2`); a failed button keeps the old URL; after success
    `:unchanged`; no `PHX_HOST` keeps ruoc's URL.
- ruoc: preflight and simple request on `/tg/api/me` from the allowed origin get the headers incl.
  `X-Telegram-Bot`; another origin gets none; `ALLOWED_ORIGINS` origins get no headers on `/tg/api/`;
  other paths unchanged.

## Rollout

1. ruoc: `TG_PANEL_ORIGINS` code, deploy, set `TG_PANEL_ORIGINS=https://druzhok.oldey.dev` in
   `/etc/ruoc/ruoc.env` (backup first), restart.
2. Caddy: generate `DRUZHOK_EDGE_SECRET`, add it to `/etc/caddy/env` and `/etc/druzhok/druzhok.env`
   (backups first), patch the prod `druzhok.oldey.dev` block with the `header_up` line, `caddy validate`,
   reload. Mirror the line in `ops/Caddyfile`.
3. druzhok: merge, deploy. Buttons still point at ruoc until something triggers the cabinet.
4. `sudo ops/druzhok bind-cabinet igorhermes`; check Бот, Файлы, Счёт and one payment in Telegram Web and
   on the phone.
5. Other bots move on their next start, wake or owner message; `bind-cabinet` (all) moves them at once.
6. Later: remove ruoc's `/tg/` page; route bot subdomains to BotSite and add site links.

## Open questions

- Show the owner the ids in the allowlists, or counts only (this draft: counts)?
