# Website hosting per bot

Date: 2026-04-16
Status: Draft — pending user review

## Problem

Users regularly ask their bots things like "build me a landing page and send the link". Today there is nothing a bot can do with such a request: files written to the workspace are not reachable from the public internet, and the bot has no credentials for external deploy targets. The bot can only return HTML inline as a message, which is an unacceptable UX.

We want every bot to be able to publish small static sites (HTML/CSS/JS/assets) to a public URL, on request. Content creation happens through the bot's existing file-write tools; the hosting infrastructure lives outside the bot container, serving directly from the bot's workspace volume.

## Scope

A per-bot boolean `website_hosting_enabled` (new `instances` column). When enabled, files the bot writes to `/opt/data/workspace/sites/<site-name>/...` inside its container are served publicly at `https://<bot-name>.oldey.dev/<site-name>/...`. The bot is taught the convention via a section appended to `workspace/AGENTS.md`. The dashboard gets a toggle and a read-only list of the bot's current sites.

**In scope:**

- Caddy installed on the VM as a new systemd service, terminating TLS for `*.oldey.dev`.
- Wildcard DNS + wildcard TLS cert for `*.oldey.dev`.
- Dashboard (`dashboard.oldey.dev` or current URL) moves behind Caddy reverse-proxy.
- Per-bot `website_hosting_enabled` column, emitted to the bot container as `BOT_SITE_BASE_URL` env var when on (empty when off).
- `workspace-template/AGENTS.md` gains a "Publishing websites" section.
- A druzhok `sync_agents_md/2` helper adds the section to existing bots' workspaces on every start (idempotent).
- Dashboard settings tab: new "Website Hosting" section with a toggle and a read-only list of `(name, URL, size, mtime)` for each site in `workspace/sites/`.
- Druzhok-branded default HTML page served when a requested URL doesn't match any site or the toggle is off.
- Dashboard session cookie audit: must be `Domain=oldey.dev` exactly, `SameSite=Strict`, `Secure`. Verify before Caddy flips on TLS termination for the full apex.

**Explicitly out of scope:**

- Automatic phishing / content scanning.
- Per-IP rate limiting at the proxy (deferred; easy to add in Caddy when needed).
- Cloudflare or any CDN in front (deferred).
- Dashboard "delete site" button (user asks the bot, or SSH in).
- Admin-level "nuke all sites on the platform" emergency switch.
- Site analytics / view counts.
- Custom per-site domains (BYO domain).
- Hard disk quotas (kernel-level or userspace).
- Migrating away from the shared `oldey.dev` domain. Reputation-coupled architecture accepted for this scale.

## Why `*.oldey.dev` (same domain)

User decision. The alternative — registering `oldey-sites.dev` or similar purely for bot-hosted content — would isolate phishing-reputation risk from the dashboard. Rejected at this scale (4 trusted users) on the grounds that the probability of a malicious actor inside the current user set is near zero and a separate domain is easier to add later than to back out of. If scale grows beyond trusted-users, revisit.

## Architecture

```
                                          (TLS termination, wildcard cert)
  Internet ──HTTPS──► Caddy (on VM) ──► static file_server / reverse_proxy
                       │
                       ├── host = <bot>.oldey.dev       (bot regex-validated)
                       │     docroot = /home/igor/druzhok-data/v4-instances/<bot>/workspace/sites/
                       │     file_server, dotfiles hidden
                       │     handle_errors + unknown subdomain → druzhok default page
                       │
                       └── host = dashboard.oldey.dev   (or whatever current apex)
                             reverse_proxy to Phoenix on 127.0.0.1:4000
```

Caddy becomes the front door for everything HTTPS. Phoenix continues listening on `127.0.0.1:4000` and is no longer directly exposed.

## Components

### Caddyfile

Single declarative file, version-controlled in the druzhok repo (e.g. `v4/druzhok/config/Caddyfile`). Approximate shape:

```caddy
*.oldey.dev {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }

    @dashboard host dashboard.oldey.dev
    handle @dashboard {
        reverse_proxy 127.0.0.1:4000
    }

    @botsite host_regexp bot ^([a-z0-9][a-z0-9-]*)\.oldey\.dev$
    handle @botsite {
        root * /home/igor/druzhok-data/v4-instances/{re.bot.1}/workspace/sites
        file_server {
            hide .* _*
        }
        handle_errors {
            root * /opt/druzhok-assets/default-page
            file_server
        }
    }

    # Fallback: unknown subdomain → default druzhok page
    handle {
        root * /opt/druzhok-assets/default-page
        file_server
    }
}
```

DNS-01 via Cloudflare's API is the assumed path; adjust when we confirm the actual DNS provider for `oldey.dev`.

### Druzhok (Elixir) changes

- Migration: `alter table(:instances) add :website_hosting_enabled, :boolean, default: false, null: false`.
- Schema: add `field :website_hosting_enabled, :boolean, default: false` and include in `cast/3`.
- `Druzhok.Runtime.Hermes.env_vars/1`: emits `"BOT_SITE_BASE_URL" => "https://#{instance.name}.oldey.dev"` when the flag is on; omits the key or emits empty string when off.
- `Druzhok.Runtime.Hermes.sync_config/2` gains a new step `sync_agents_md/2` that reads `workspace/AGENTS.md`, appends the "Publishing websites" section if absent, no-op if present.
- New module `Druzhok.SiteLister`: given an instance, scans `<workspace>/sites/*/` and returns `[%{name, url, size, mtime}]`.
- Dashboard (`settings_tab.ex`): new "Website Hosting" section inside the Settings tab, below "Group Chats". Contains:
  - Checkbox "Enable website hosting — publish static sites at `<bot>.oldey.dev`". `phx-click` toggles the DB field and restarts the bot.
  - Conditional on toggle being on: a list of the bot's sites with name, clickable URL, size, and modification time. Re-scanned each LiveView mount.
  - Conditional on toggle being off: helper text "Enable to let the bot publish static pages".

### Workspace-template change

`v4/druzhok/workspace-template/AGENTS.md` gains (appended at the end, with a clear heading):

```markdown
## Publishing websites

If the user asks you to build a web page, landing page, demo, etc.:

1. Check env var `BOT_SITE_BASE_URL`. If empty or unset, website hosting
   is not enabled for this bot — tell the user to enable it in the
   dashboard and do not attempt to publish.
2. Choose a short site name matching `^[a-z0-9][a-z0-9-]*$` (max 50 chars).
3. Write all files under `/opt/data/workspace/sites/<name>/`. The entry
   file should be `index.html`. Supported content: HTML, CSS, JS,
   images, small static assets. Keep per-site size under ~50 MB.
4. After writing, reply to the user with a single clickable URL:
   `$BOT_SITE_BASE_URL/<name>/`.
5. To delete a site, `rm -rf /opt/data/workspace/sites/<name>/`.

Files under `sites/<name>/` are served publicly. Never put secrets,
tokens, or files starting with a dot in there — the proxy blocks them,
but treat that as a defense-in-depth layer, not a free pass.
```

### Host-side assets

- `/opt/druzhok-assets/default-page/index.html` — druzhok-branded static page shown when a request doesn't hit a real site. Content: brief "Nothing to see here yet" + a link back to `dashboard.oldey.dev`. Shipped as part of the deploy process (rsync'd during first install, updated with each deploy).

## Data flow

Bot creation (new bot): existing flow runs `workspace_files/1` which seeds `AGENTS.md` from the template; the sites section is now always included. `BOT_SITE_BASE_URL` only emitted when toggle is on.

Toggle on via dashboard: `phx-click toggle_website_hosting` → `update_instance(website_hosting_enabled: true)` → `restart_bot` → `BotManager.start` calls `sync_config/2` (which includes `sync_agents_md/2`, a no-op if the section is already there) → container starts with `BOT_SITE_BASE_URL=https://<bot>.oldey.dev`.

User asks "build me a landing page": the agent reads `AGENTS.md`, sees the "Publishing websites" section, checks `$BOT_SITE_BASE_URL` is set, writes files to `/opt/data/workspace/sites/<name>/`, replies with the URL.

User visits URL: Caddy → regex-validates bot name → reads host path → serves file. Miss → default page. Bot toggle off → directory likely doesn't exist (or if it does, Caddy still serves it; the toggle-off condition is enforced by AGENTS.md's instruction to check env var, not by Caddy blocking the dir). A stricter read of "toggle off" would require Caddy to refuse serving the dir based on DB state, which adds complexity; MVP accepts that toggle-off is agent-enforced, not proxy-enforced. Files on disk remain readable if the user flips the toggle back on.

Files on disk are the single source of truth. No sites DB table.

## Security controls

### Must-have (pre-launch)

1. **Cookie scope audit.** Phoenix session cookie must be `Domain=oldey.dev` (host-only), `SameSite=Strict`, `Secure`. If currently wildcard-scoped or not `Secure`, fix before Caddy deploys.
2. **Caddy docroot confined** to `workspace/sites/`, never `workspace/` or higher.
3. **Bot-name regex validation** at proxy via `host_regexp`. Mismatches fall through to the default-page handler.
4. **Dotfile hiding** via `file_server { hide .* _* }`.

### Advisory (documented in AGENTS.md, not enforced)

- Max ~50 MB total sites per bot.
- Max ~100 files per site.
- No secrets under `sites/`.
- No filenames starting with `.` or `_`.

### Non-solvable risks — accepted

- Phishing on `oldey.dev` is inevitable with arbitrary static hosting; at 4 trusted users, probability near zero.
- Domain-reputation damage from a single phishing incident cascades to the dashboard. Mitigation: if it happens, move to a separate content domain.
- Certificate Transparency logs leak bot names publicly. Accepted — names are not secrets.
- Hostile JS in user sites can abuse visitors. Cannot prevent on static hosting.
- Egress costs are externalised to the operator (you).
- Legal / DMCA / law-enforcement routing lands on the domain registrant.

## Testing

Unit tests (druzhok ExUnit):

- Changeset accepts `website_hosting_enabled: true/false`.
- `env_vars/1` emits `BOT_SITE_BASE_URL` iff flag on.
- `sync_agents_md/2` appends the section when absent; no-ops when present; produces identical output on a second invocation.
- `SiteLister` module: given a tmp dir with `sites/foo/` and `sites/bar/`, returns both with correct URL/size/mtime; handles missing `sites/` dir gracefully.

Manual smoke tests (after deploy):

1. Enable `website_hosting_enabled` for Vasya via dashboard.
2. Ask Vasya in Telegram: "create a landing page for my BMW service and send me the link."
3. Confirm she returns a URL of the form `https://vasya.oldey.dev/<name>/`.
4. Open URL in browser — page renders.
5. Open `https://vasya.oldey.dev/does-not-exist/` — default page.
6. Open `https://unknown-bot.oldey.dev/` — default page (no such bot).
7. Toggle Vasya's hosting off — site directory remains; visiting the URL still serves (expected per MVP decision). Agent should refuse to create new sites while off.
8. Toggle back on — agent can publish again.
9. Dashboard "Website Hosting" section in Vasya's settings shows the site with its URL and size.
10. Cookie audit: confirm Phoenix session cookie is `oldey.dev` scoped (not `.oldey.dev`), `Secure`, `SameSite=Strict`.

## Operational notes

- Caddy provisions the wildcard cert on first start via DNS-01. Need `CLOUDFLARE_API_TOKEN` (or whichever provider) in Caddy's environment. Document the token acquisition path in the deploy runbook.
- Wildcard DNS: add a single `*.oldey.dev A <VM-ip>` record. Individual subdomains (`dashboard.oldey.dev`) still work; wildcard catches the rest.
- Dashboard moves behind Caddy → if Caddy fails, dashboard is unreachable. Keep a "break glass" path (SSH + port-forward to Phoenix on `127.0.0.1:4000`) documented.
- Feature flag default is off. Turning on for a bot triggers a restart that re-syncs the AGENTS.md section. Existing Vasya/Рун are unaffected until the operator toggles.
- The default-page assets live under `/opt/druzhok-assets/default-page/` on the host; deploy step rsyncs them from `v4/druzhok/priv/default-page/` (or similar).

## Open items for implementation

- **DNS provider for `oldey.dev`.** The spec assumes Cloudflare for DNS-01; confirm during implementation and adjust the Caddyfile `tls` block accordingly (Caddy supports many providers via plugins).
- **Current dashboard URL.** Spec assumes `dashboard.oldey.dev`. Confirm the operator's current dashboard URL and whether to keep or change it during the Caddy migration.
- **Assets source path.** `v4/druzhok/priv/default-page/` is one reasonable location for the default-page HTML; alternative is `v4/druzhok/workspace-template/default-page/`. Decide during implementation.
