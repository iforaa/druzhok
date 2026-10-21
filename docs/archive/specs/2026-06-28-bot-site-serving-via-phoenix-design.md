# Serve bot-published sites through Phoenix

**Date:** 2026-06-28
**Status:** Approved

## Problem

Bots publish static sites to `<data_root>/<bot>/workspace/sites/<name>/`, served at
`https://<bot>.oldey.dev/<name>/`. Caddy serves these directly from disk as the
`caddy` user. But the hermes runtime calls `secure_parent_dir()`
(`hermes_constants.py:335`) which `chmod 0700`s `HERMES_HOME` — the bind-mounted
botdir — on every auth/state write. So the `caddy` user cannot traverse into the
botdir, and **every** request to a bot subdomain returns 403 (a misleading
"Nothing here yet" served via Caddy's `handle_errors`). The bot writes the files
correctly; only the serving layer is broken. Host-side `chmod`/ACL fixes are wiped
within minutes by the next hermes write.

## Approach

Stop having Caddy read bot files from disk. Reverse-proxy bot subdomains to the
Phoenix app, which runs as `igor` — the owner of every site file — so there is no
permission problem at all. A plug detects bot-subdomain requests by `Host` header,
serves the static file, and **halts before the dashboard router**, so bot
subdomains can only ever reach site files (never the dashboard, LiveView, or the
`/v1/*` proxy routes).

This is entirely within the `v4/druzhok` repo — no hermes source fork (which would
need re-applying on every hermes upgrade), no host-side perm reconcile loop.

## Components

1. **`config/Caddyfile`** — in the `*.oldey.dev` `@botsite` block, replace the
   `root` + `file_server` with `reverse_proxy 127.0.0.1:4000`. Caddy keeps
   terminating TLS and passes the original `Host` header through (its default).
   The bare `oldey.dev` dashboard block is unchanged. The non-matching-host
   fallback + `handle_errors` default page stay as-is.

2. **`Druzhok.BotManager.data_root_base/0`** — change from `defp` to `def` so the
   web layer shares the one canonical data-root resolution
   (`System.get_env("DRUZHOK_DATA_ROOT")` with dev fallback).

3. **`Druzhok.SiteLister.sites_dir/1`** — new: `bot_name -> <data_root>/<bot>/workspace/sites`.
   Single source of truth for where a bot's sites live; used by the plug.

4. **`DruzhokWebWeb.Plugs.BotSite`** (new) — inserted in `endpoint.ex` immediately
   before `plug DruzhokWebWeb.Router` (after `Plug.Head`, so HEAD is already
   normalized to GET). Behavior:
   - Match `conn.host` against `^([a-z0-9][a-z0-9-]+)\.oldey\.dev$`. No match
     (incl. bare `oldey.dev`) → return `conn` untouched; the Router handles it.
   - Match → resolve `SiteLister.sites_dir(bot)`, map `conn.path_info` to a file
     under it, serve it, and `halt()`.

5. **`apps/druzhok_web/priv/default-page/index.html`** — copy of the branded
   "Nothing here yet" page, bundled in the release so the plug can serve it as the
   404 body via `Application.app_dir/2`.

## Data flow

`GET https://igorhermes.oldey.dev/wc2026-bracket/`
→ Caddy TLS + `reverse_proxy 127.0.0.1:4000` (Host preserved)
→ Phoenix endpoint → `BotSite` plug sees host `igorhermes.oldey.dev`
→ root `<data_root>/igorhermes/workspace/sites`
→ `path_info ["wc2026-bracket"]` → directory → `wc2026-bracket/index.html`
→ `send_file` 200 (Phoenix reads as `igor`, no perm issue) → `halt`.

Dashboard requests to `oldey.dev` don't match the host regex → fall through to the
Router exactly as today.

## Security

- **Path traversal:** reject any `path_info` segment that is `.`/`..`, empty, or
  starts with `.`/`_` (dotfile/underscore parity with Caddy's `hide .* _*`). After
  `Path.join` + `Path.expand`, assert the result is the root or strictly under
  `root <> "/"`; otherwise 404. Belt-and-suspenders against `..`, encoded
  traversal, and symlink escape.
- **Dashboard isolation:** the plug `halt()`s on bot subdomains, so no session /
  LiveView / `/v1/*` route is reachable from `*.oldey.dev`. Existing host-only
  `SameSite=Strict` cookie hardening stays as defense-in-depth.
- **Method:** only `GET`/`HEAD` (Plug.Head folds HEAD→GET); anything else → 405.

## Error handling

Unknown bot, missing `sites/` dir, missing file, or directory without `index.html`
→ branded `priv/default-page/index.html` with **404** status.

## Testing (TDD)

Plug unit tests with `Plug.Test`, using a tmp `DRUZHOK_DATA_ROOT`:
- dashboard host (`oldey.dev`) → passes through untouched (not halted)
- bot host + existing file → 200 + correct `content-type`
- bot host + directory → serves `index.html`
- missing site/file → branded 404
- traversal (`..`, encoded, absolute, symlink escape) → never escapes root → 404
- dotfile / underscore segment → 404 (hidden)
- non-GET → 405
- `SiteLister.sites_dir/1` returns `<data_root>/<bot>/workspace/sites`

## Deploy

`mix compile` → restart `druzhok` → copy `Caddyfile` to `/etc/caddy/Caddyfile` →
`systemctl reload caddy` → `curl https://igorhermes.oldey.dev/wc2026-bracket/`
expect 200, and confirm it stays 200 (no permission race). The transient host
`chmod`s applied during debugging become irrelevant.
