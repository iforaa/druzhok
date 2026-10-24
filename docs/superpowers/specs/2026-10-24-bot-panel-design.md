# Bot panel: the cabinet moves to druzhok

Status: approved after revmux rounds 01–03, 2026-10-24. Follows ruoc-gateway
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
3. Everything druzhok serves is **read only**. Nothing in v1 changes a bot.
4. Счёт behaves exactly as today, calling ruoc's `/tg/api/*` cross-origin.
5. Opening the panel never wakes a sleeping bot: it reads the instance row, the disk, and the unit's state
   (one `BotManager.status/1` call per `GET /app/api/bot`, which in prod runs `sudo druzhok-ctl status`).

## Non-goals (v1)

- Editing settings, SOUL.md, memory or jobs; clearing history. (v2; writes would go through
  `BotSettings.update/2` and hermes's own CLI via `druzhok-ctl exec`, never by writing hermes's locked
  files. The authentication below stops a bot from minting init data; it does not stop a bot from
  phishing the owner's genuine init data, so v2 writes need more, see open questions.)
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

- Caddy's `druzhok.oldey.dev` block: `import /etc/caddy/druzhok-edge.caddy`, a `root:caddy 0640` file holding
  `header_up X-Druzhok-Edge <secret>` (sets, so a client-sent value is overwritten). An import rather than
  `{env.…}`: Caddy fronts all of ruoc's traffic, so it must change by reload, and a reload never re-reads
  `EnvironmentFile=`. The same secret is `DRUZHOK_EDGE_SECRET` in `/etc/druzhok/druzhok.env`, never a
  settings row. The prod Caddyfile drifts from the repo: the rollout
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

All of `/app` sits behind `Plugs.Edge`. The bundle is served by `PanelPageController.asset/2` inside the
`/app` scope (a file-name allowlist and `send_file`, not in the endpoint, so the edge check covers it). `/app/index.html` and any other path under `/app/`
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
   requests a minute, ETS counter, 429 `rate_limit_error`.
2. Parse `Authorization: tma <initData>` and `X-Telegram-Bot` (1–20 digits). Missing or malformed → 401
   `init_invalid`. The init data is split into pairs once, into a single-valued map: **a key that occurs
   more than once → 401 `init_invalid`** (as ruoc's `telegram_init.go`). The signed strings below and every
   value read afterwards (`user`, `auth_date`) come from that same map.
3. **Find the bot**: the instance, `delete_requested` false, whose `Instance.telegram_bot_id/1` equals the
   header. None → 404 `not_found`. (A scan of the instances table; a few dozen rows.)
4. **Telegram's Ed25519 signature** (the third-party scheme, as ruoc's `telegram_init.go`): the
   data-check string is `"<bot_id>:WebAppData\n"` followed by every `key=value` pair except `hash` and
   `signature`, sorted by key, values URL-decoded, joined by `\n`; `signature` is base64url, trailing `=`
   trimmed before decoding (as ruoc does), and must verify with Telegram's production public key
   `e7bf03a2fa4602af4580703d88dda5bb59f32ed8b02a56c187fe7d34caed242d`
   (`:crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])`). Missing or invalid → 401 `init_invalid`.
   **This is the check a bot cannot mint:** every bot holds its own token (`TELEGRAM_BOT_TOKEN` in its env,
   `Runtime.Hermes.env_vars/1`), so a token HMAC alone could be computed by the bot itself for its owner's
   id. Only Telegram holds the Ed25519 private key. A bot *can* still phish genuine init data: with its
   token it can point the owner's menu button or an inline `web_app` button at a page it controls, and
   Telegram hands that page real init data for this bot and owner, usable for `PANEL_INIT_MAX_AGE`. In v1
   that exposes only what the bot can already read; it is the reason v2 writes need an extra step.
5. **Bot-token HMAC** (the first-party scheme), as a second check: `secret = HMAC_SHA256(key="WebAppData",
   msg=bot_token)`; `data_check_string` = every pair except `hash`, sorted, URL-decoded, joined by `\n`
   (`signature` included); `hash` must equal the hex HMAC, constant-time. It binds the data to this bot's
   current token. Mismatch → 401 `init_invalid`.
6. **Freshness**: `auth_date` no older than `PANEL_INIT_MAX_AGE` (default 24 h; v1 is read only) and not
   more than 60 s in the future. Else 401 `init_stale`.
7. **Owner**: `user.id` from the init data must equal `instances.owner_telegram_id`. Else 403 `not_owner`.
8. **Cabinet off**: `cabinet_off` true → 403 `cabinet_off`.

The handler gets the instance. No response ever carries the token.

**Errors** use ruoc's envelope, `{"error": {"type": "<code>", "message": "<text>"}}`, so the shared
`api.ts` reads both APIs the same way. Codes: `init_invalid`, `init_stale`, `not_owner`,
`rate_limit_error` (ruoc's name), `not_found`, `cabinet_off`, `not_text`. The page's `explain()` /
`fatal()` gain `cabinet_off` (fatal), `not_found` (shown; `GET /app/api/bot` failing with it stops the page,
a missing file does not) and `not_text` (shown in place of the file).

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
  "access": { "allow_all_users": false, "allowed_users": 2, "free_response_chats": 3 },
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
- `title` and `username` from `Panel.profile/1` since iteration 2 (see below): its own `getMe` cache, an hour per
  token; a miss waits at most 3 s, a failure keeps the last known name and is not retried for a minute.
  `username` falls back to `Addressed.username/1`. `settings.model_name` is ruoc's catalogue name as last fetched
  (`Ruoc.cached_models/0`, never waits on ruoc), `support_url` is Settings `support_url` when it is https.
- `access` gives counts only, the ids being other people's (operator decision, 2026-10-24):
  - `allow_all_users`: `instances.allow_all_telegram_users` (hermes's `TELEGRAM_ALLOW_ALL_USERS`); the page
    shows «все» instead of a count when true.
  - `allowed_users`: the distinct ids of the owner, the row's `allowed_telegram_ids`, and the keys of
    hermes's pairing file `platforms/pairing/telegram-approved.json` (read through `TenantFiles`, not
    `Hermes.read_allowed_users/1`, which uses a plain `File.read`), minus the `__closed__` marker.
  - `free_response_chats`: the length of `allowed_telegram_chats`, which is the list of chats where the bot
    answers without a mention (not an access list).

### Files: `Druzhok.TenantFiles`

The safe walk moves out of `Plugs.BotSite` into `Druzhok.TenantFiles`; BotSite and the panel both use it.

**Opening a file** (as BotSite does today): `lstat` every component below the tenant dir; every
intermediate a real directory, the leaf a regular file, no symlink anywhere; open; re-walk and compare the
descriptor's inode and device. Bytes and `stat` figures come from the verified descriptor
(`:file.read_file_info(fd)`), never from a second lookup by name. **The opened file must also be owned by
the tenant dir's owner** (the bot's uid): the walk cannot stop a bot that swaps an intermediate directory
for a symlink between lookups, but another tenant's files have another owner and host files belong to
root, so such a swap reaches only the bot's own files. (Every file the panel reads is the bot's; checked
on prod.)

**Listing a directory** (website tree, skills discovery) is **not** done by druzhok's own process. An
in-process walk (`lstat`, then `File.ls`, then `lstat` per entry) resolves the whole path again at each
step, and the bot, which owns these directories, can swap a parent for a symlink between two steps; with
druzhok's `CAP_DAC_READ_SEARCH` that lists another tenant's tree. So a listing runs **as the bot's own
user**, through `Druzhok.Host.exec/2` (prod: `druzhok-ctl exec`, a transient unit with the bot's uid):

```
/bin/sh -c 'exec find -P "$1" -mindepth 1 -maxdepth "$2" \( -name ".*" -o -name "_*" \) -prune -o -printf "%y %s %P\0" 2>/dev/null' find <root> <depth>
```

- `<root>` is a fixed relative path from the unit's cwd `workspace/`: `sites` (= `<tenant>/workspace/sites`,
  the root BotSite serves) and `../skills` (= `<tenant>/skills`). It is passed as a positional argument,
  never interpolated into the script.
- GNU find is required (`-printf`); the binary comes from config `:find_bin` (prod `/usr/bin/find`; macOS
  dev `gfind` from Homebrew findutils).
- Records are NUL-separated `type size path`; druzhok keeps type `f` (and `d` for structure), drops
  everything else (`l` symlinks included), stops at the entry cap, and treats an unparsable record as the
  end of the list. A race now reaches only what the bot's uid can read: its own tree and world-readable
  host files, which the bot could read and repeat to its owner anyway. Other tenants' dirs are 0700.
- A listing costs one transient unit (a few hundred ms); it does not start or wake the bot, and works
  whatever the unit's state. Prod goes through `Druzhok.Host.exec/2` (`druzhok-ctl exec`). Dev and test do
  **not** use `Host.Process.exec/2` (it needs the bot's port process running): the lister runs the same
  command directly with `System.cmd`, cwd `<tenant>/workspace`. Tests inject the lister.

Any file whose contents a listing needs (a skill's front matter) is then read through the verified open
above, by druzhok, never trusted from the listing.

**Every component from the tenant dir down is checked**, for listings too: before listing `sites/`,
`workspace/` must `lstat` as a real directory (BotSite's "a symlinked workspace is not served" rule);
before listing `skills/`, `skills` itself. A symlinked component → the section is absent.

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
| Paired users (keys only) | `platforms/pairing/telegram-approved.json` | 256 KiB |
| Own skills | `skills/<name>/SKILL.md` and `skills/<category>/<name>/SKILL.md` | 256 KiB each, 200 skills |
| Website | `workspace/sites/**` (tree only) | 2000 entries, depth 8 below `sites/` |

Reading never takes hermes's `fcntl` locks. `cron/jobs.json` is replaced atomically (`cron/jobs.py`,
`mkstemp_beside` + `atomic_replace`), and so are `memories/MEMORY.md` and `USER.md`
(`tools/memory_tool_store.py`, `atomic_write_text`), so a read sees one version or the other. SOUL.md and
SKILL.md writes are not verified; a torn read shows partial text until the next open.

**Text and limits:** read at most limit + 4 bytes. If the file is longer than the limit, cut at the limit,
then trim back to the start of the last incomplete code point: drop any trailing continuation bytes
(`10xxxxxx`) **and the lead byte that begins the incomplete sequence**, at most 3 bytes in all (e.g. a cut
right after `0xD0`, the first byte of «д», drops that `0xD0`). Set `"truncated": true`. The UTF-8 check
runs on the trimmed buffer, so a valid file never fails because of the cut. Invalid UTF-8 inside the kept text → 422 `not_text`. JSON files (`jobs.json`) over their limit →
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

- `name`: stored `name` trimmed; if empty, the first of `prompt`, `skills[0]` (or `skill`), `script`, `id`
  that is non-empty, **cut to 50 characters whichever it is** and trimmed, else «cron job».
- `schedule`: stored `schedule_display`; if empty, `schedule.display`, `.value`, `.expr` or `.run_at` (first
  non-empty), or `schedule` itself when it is a string; else «?».
- `state` (hermes's `effective_job_state`), in order:
  1. stored `state` `completed` or `error` → kept;
  2. `enabled` (default true) false → `paused` if the stored state is `paused` or `paused_at` is set,
     else the stored state, or `paused` when it is empty;
  3. `enabled` true → `scheduled` if the stored state is `paused` or `paused_at` is set, else the stored
     state, or `scheduled` when it is empty.
- Also: `prompt`, `next_run_at`, `last_run_at`, `last_status`, `repeat` (`times`, `completed`).

Delivery targets (`deliver`, chat ids) are not shown.

### Skills

- **Discovery:** the bot-uid listing of `skills/` (depth 3); every `SKILL.md` regular file at
  `<name>/SKILL.md` is an uncategorised skill, at `<category>/<name>/SKILL.md` a categorised one. Dot and
  `_` entries are pruned. hermes allows both
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

The bot-uid listing of `workspace/sites/` (the root BotSite serves), as `[{site, path, size}]` grouped by top-level
directory (a bot can publish several sites; `AGENTS.md` tells it to use `sites/<имя>/`). `path` is relative
to `sites/`. Dot and `_` entries are skipped, as BotSite does. No URLs or links in v1 (see non-goals).
`website_hosting_enabled` false, or no `sites/` directory → `null`.

### `Druzhok.Cabinet` changes

With `PHX_HOST` set, the panel URL is `https://<PHX_HOST>/app/?bot=<bot_id>` and it replaces ruoc's
`mini_app_url` everywhere:

- `bind/2` writes the panel URL into `cabinet_url`. ruoc's reply is still required (it proves the binding);
  its URL is ignored.
- `bind_now/1`: the `:unchanged` branch also requires `cabinet_url == panel_url`; the `:button` branch
  (binding current, button or URL stale) sets the button to the panel URL with no ruoc call, and **only
  after Telegram accepts it** writes `cabinet_url = panel_url` together with `cabinet_menu_set: true`, in
  one update.
- `button_moment?/2` is also true when `cabinet_url != panel_url`, so the owner's next private message
  moves a bot that is never restarted.
- The out-of-money notice opens `…/app/?bot=<bot_id>&tab=billing`.
- In the `:button` branch a failed `setChatMenuButton` leaves `cabinet_url` as it was, so the next trigger
  tries again; a success writes the panel URL, after which every check is `:unchanged` (no loop, no ruoc
  call). `bind/2` keeps today's order (URL first, with `cabinet_menu_set: false`, so a bound bot always has
  an address for the out-of-money notice and the button is retried).

No `PHX_HOST` (dev, test) → everything behaves as today, with ruoc's URL.

### The page

- Source moves from ruoc `web/miniapp/` to `apps/druzhok_web/assets/app/` (Vite, React, TypeScript, the
  same `telegram.ts`, `api.ts`, styles). Build output `apps/druzhok_web/priv/static/app/`, committed, as
  ruoc commits `web/dist`. `node_modules/` is gitignored, and the CLAUDE.md deploy rsync gains
  `--exclude=node_modules` (it copies `apps` from the working tree, where `.gitignore` does not apply).
  The deploy steps gain `ops/build-app.sh` before the rsync, and a test fails when the committed
  `index.html` references a bundle file that is not committed.
- `api.ts` gets two bases: `/app/api/` for the panel, `<billing_url>/tg/api/` for billing.
- Tabs at the bottom; `?tab=billing` opens Счёт. Text in Russian only in v1 (the billing screens it inherits
  are Russian-only; English is a later change).
- Markdown renders with `marked`, raw HTML in the source escaped; links open with `openLink`.
- Errors from either API are shown by kind (`explain()`, localized), with the reopen hint for
  `init_stale`.
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
| ruoc down | the bot and its files work; Главная has no balance, Счёт shows ruoc's error |
| druzhok down | nothing opens (the page is druzhok's) — accepted; druzhok down means the bots are down too |
| bot asleep | everything works; nothing wakes it |
| owner changed | old owner gets 403 `not_owner`; `Druzhok.Cabinet` already resets their button |
| init data from another bot | Ed25519 fails (bot id is in the signed string) → 401 |
| a bot forging init data with its token | Ed25519 fails → 401 |
| a bot phishing the owner's real init data (fake `web_app` button) | passes for up to 24 h; v1 shows only what the bot can read; v2 writes need more (open questions) |
| a bot calling `127.0.0.1:4000/app/…` | no edge header → 404 |

## Tests

- Druzhok:
  - init data: a vector signed with a test Ed25519 key (the verifier takes the public key as config, prod
    default above) and a test token passes; a valid token HMAC with a missing or wrong signature fails; a
    valid signature with a wrong HMAC fails; another bot id fails; a changed field, a stale or future
    `auth_date` fail; a duplicated `user` key fails; a padded signature passes;
  - `Plugs.Edge`: missing, wrong, and unconfigured secret → 404 for page, bundle and API;
  - `PanelAuth`: unknown bot, non-owner, `cabinet_off`, deleted bot, rate limit (keyed on the XFF hop);
  - `TenantFiles`: a symlinked `SOUL.md`, a symlinked `memories/`, a swap between walk and open (the
    BotSite tests move with the code); a symlinked `.bundled_manifest`, a symlinked pairing file;
    truncation right after the lead byte of a 2-byte («д») and of a 3-byte character, and mid-sequence,
    each returns valid text with `truncated: true`; invalid UTF-8 → 422;
  - listings: the record parser keeps `f`/`d` and drops `l`; the entry and depth caps; an unparsable record
    ends the list; a symlinked `workspace/`, `sites/` or `skills/` → section absent; the direct lister with
    a real GNU find over a tree holding regular files plus symlinked files and directories reports every
    regular file and none of the symlinks (skipped when `:find_bin` is missing or not GNU); the website
    listing reads `workspace/sites`, not `<tenant>/sites`;
  - `/app/api/bot`: no secret, account id or owner id in the encoded JSON; the state table; `access` with
    `allow_all_users` true, with paired users, and with the owner counted once;
  - errors: every code comes in the `{"error": {"type", "message"}}` envelope;
  - skills: uncategorised and categorised own skills listed and opened; a bundled one (by front-matter
    name) excluded; a path not in the own list → 404;
  - jobs: name/schedule/state derivations match the cases above, incl. a disabled job with `paused_at` and
    stored state `scheduled` (→ `paused`) and a long `script` fallback name (cut to 50); `{"jobs": …}` and
    bare list; garbage;
  - `Cabinet`: a bot bound on ruoc's URL with the button set moves to the panel URL on `bind_now` (no ruoc
    call) and on the owner's message (`button_moment?/2`); a failed button keeps the old URL and
    `cabinet_menu_set`; after success `:unchanged`; `bind/2` still writes the URL first; no `PHX_HOST` keeps
    ruoc's URL.
- ruoc: preflight and simple request on `/tg/api/me` from the allowed origin get the headers incl.
  `X-Telegram-Bot`; another origin gets none; `ALLOWED_ORIGINS` origins get no headers on `/tg/api/`;
  other paths unchanged.

## Rollout

1. ruoc: `TG_PANEL_ORIGINS` code; set `TG_PANEL_ORIGINS=https://druzhok.oldey.dev` in `/etc/ruoc/ruoc.env`
   (backup first) *before* `deploy/deploy.sh`, so the new colour starts with it. Done 2026-10-24 (`42692cf`).
2. Caddy: generate the secret, write `/etc/caddy/druzhok-edge.caddy` and `DRUZHOK_EDGE_SECRET` in
   `/etc/druzhok/druzhok.env` (backups first), patch the prod `druzhok.oldey.dev` block with the `import`,
   `caddy adapt` (`caddy validate` fails without Cloudflare's token), then `systemctl reload caddy`, never a
   restart. Check `curl -s -o /dev/null -w '%{http_code}' https://druzhok.oldey.dev/app/` → 200 once druzhok
   is deployed (404 before). Mirror the line in `ops/Caddyfile`. Done 2026-10-24.
3. druzhok: merge, deploy. Buttons still point at ruoc until something triggers the cabinet.
4. `sudo ops/druzhok bind-cabinet igorhermes`; check Бот, Файлы, Счёт and one payment in Telegram Web and
   on the phone.
5. Other bots move on their next start, wake or owner message; `bind-cabinet` (all) moves them at once.
6. Later: remove ruoc's `/tg/` page; route bot subdomains to BotSite and add site links.

## Iteration 2 (2026-10-24): four tabs

The first version's three plain tabs became **Главная · Память · Счёт · Ещё** with the panel's own palette (dark
navy, or light when Telegram is light; `applyTheme` asks Telegram to paint its header to match), a floating tab
bar with icons, and placeholders while loading. Data added, all read only:

- `GET /app/api/bot`: `title`, exact-case `username`, `settings.model_name`, `support_url` (described above).
- `GET /app/api/invites`: the owner's referral codes from ruoc `GET /v1/referrals` with the bot's key, built by
  `ManagerBot.Onboarding.invites/2`, the same function «🎁 Пригласить» uses; 502 `invites_unavailable` otherwise.
- The account (`/tg/api/me`) is shared by Главная and Счёт through a page cache; Счёт always reloads it, and
  opening a payment drops it.

Главная: the bot and its state in words, the balance as the big figure, a setup checklist (receipt email, «о вас»,
a first scheduled job, a site when hosting is on; «Написать боту» closes the panel back to the chat), four
shortcuts, dismissible tips (localStorage), the limits. Счёт's limits name the day each comes back («обновится
завтра в 18:42 · через 21 ч»), the 5-hour window says it starts with the first message, the plan line and the
balance note follow ruoc's portal. Still needs ruoc: the allowance in rubles, usage by day, payment history.

## Open questions

- v2 writes: phished init data passes every check above for its lifetime. Candidates, to decide with v2:
  a short write max-age (ruoc's `TG_INIT_WRITE_MAX_AGE`, 1 h, or less); a confirmation the owner taps in
  the superbot, which the bot cannot touch; checking `chat_type`/`query_id`; druzhok re-asserting the
  menu button from time to time with `getChatMenuButton`, since today it trusts `cabinet_menu_set`.
