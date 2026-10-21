# Legacy cleanup (2026-10-21)

Status: draft. Druzhok began as a platform for several bot runtimes (its own agent, OpenClaw, Docker
sandboxes, honcho, money budgets, a dashboard). Today it runs only Hermes bots as systemd units, bills
through ruoc-gateway and is operated through `ops/druzhok`. This spec removes what that history left
behind, and fixes two defects the review found. Branch `legacy-cleanup`.

Evidence comes from grepping `apps/`, `config/`, `ops/` and from prod (2026-10-21): table row counts,
`usage_logs`, 60 days of `journalctl -u druzhok`, `/etc/druzhok/druzhok.env`.

## Steps

One commit per step, each deployed and smoke-tested (`ops/smoke.sh`, `ops/druzhok list`, bot PIDs
unchanged where no restart is expected) before the next. Tests are deleted together with the code they
cover; `mix test --cover` thresholds are lowered only if a deletion drops coverage below them.

### 1. Fixes

1. **New bots get webhook mode.** All 6 active bots use `telegram_mode = webhook`, but `BotManager.create`
   inserts the default `polling`, so a bot made by the manager bot has no relay and cannot sleep until
   the operator runs `mix druzhok.telegram_mode`. After the insert, `do_create` calls
   `Telegram.Webhook.set_mode(name, "webhook")` (the row exists, so the id is known and in range, and no
   updates are queued). A failure there is logged and leaves the bot on polling: it still works, and the
   bot is not a creation error. The first start then registers the webhook as for any webhook bot.
2. **`ops/druzhok approve <bot> <numeric id>` grants access.** `BotSettings.approve_pairing` calls
   `Runtime.Hermes.add_allowed_user`, which is a no-op, so it deletes the request and sends the welcome
   without allowing the user. `approve <bot> <id>` becomes: `allow_user` (DB allowlist + restart of a
   running bot), then the welcome message. Approving a hermes pairing code (`approve <bot> CODE`) is
   unchanged. The `pairing_codes` table goes in step 4: nothing has written it since 2026-03 (one row,
   `vasa`, expired), so `pairings <bot>` is removed from the CLI.

### 2. Dead code (no schema change)

Core (`apps/druzhok/lib/druzhok`):
- `Druzhok.Runtime` behaviour: one implementation, `for_instance/1` always returns `Runtime.Hermes`, and
  `supports_feature?` is constant. Callers use `Runtime.Hermes` directly; the dead branches in
  `BotSettings.allowed_users`/`mutate_allowlist` and the no-op `add_allowed_user`/`remove_allowed_user`
  go. `proxy_url/0` and `base_env/1` move into `Runtime.Hermes`. `proxy_url` stops reading
  `LLM_PROXY_HOST` (Docker era; not set on prod) and keeps `LLM_PROXY_PORT`.
- `Runtime.parse_user_input`: the OpenClaw `bind-telegram` branch; it becomes `String.trim`.
- `InstanceManager`: only `create/2` and `list/0` are called. They move into `BotManager`; the module
  goes, with `default_workspace`, `stop`, `delete`, `update_model`, `approve_pairing`, `approve_group`,
  `reject_group`, `get_pairing`, `get_groups`, `get_owner`.
- `Druzhok.Events` and `Phoenix.PubSub` in `DruzhokWeb.Application`: no subscriber since the dashboard
  went, and `Events` writes logs under the old `data/instances/<bot>/logs`. The endpoint's
  `pubsub_server` config goes with it (no channels, no LiveView).
- `Druzhok.AllowedChat` module (table in step 4), `Druzhok.Pairing` (table in step 4).
- `Telegram.Format` (no callers), `Telegram.API.send_document/send_photo/get_file/download_file/
  fetch_file_by_id` (test-only).
- `SiteLister.list/1` and helpers; `sites_dir/1` stays (BotSite plug).
- `I18n`: every key but `:welcome_default`, and `lang/1`.
- `Instance.get_by_api_key/1`, `generate_api_key/0`; `Host.egress_check` (behaviour, both backends,
  stub); `BotManager.stats/1`, `logs/1`; `Ruoc.console_url/1`, `price_label/1`; `Settings.ruoc_keys/0`;
  `BotSettings.restart_fields/0` and `api_key` in its `@secret`; `Druzhok.hello` and its test.
- `group_sessions_per_user` out of `BotSettings` `@restart`: hermes's value is derived from
  `group_shared_memory`, so setting it only restarts the bot (column in step 4).
- `TokenPool` branch of `BotManager.do_create` and `TokenPool.release` in delete: the provisioner always
  passes a token. Without a token `create` returns `{:error, "telegram token required"}`. Module and
  table in step 4.
- The honcho cleanup `File.rm(honcho.json)` in `Runtime.Hermes` (no `honcho.json` left on prod).
- Mix task `druzhok.migrate_ruoc` (the CLI has `migrate-ruoc`). `druzhok.telegram_mode` stays.

Web (`apps/druzhok_web`):
- `DruzhokWebWeb.Telemetry` with `telemetry_metrics` and `telemetry_poller`; `DNSCluster` with
  `dns_cluster` and `DNS_CLUSTER_QUERY`; the unused `:auth_rate_limit` ETS table; `channel/0` in
  `druzhok_web_web.ex`; the generator placeholder comments in the application.
- Config nobody reads: `generators` (config.exs), `dev_routes` (dev.exs), `nebius_api_url` and
  `anthropic_api_url` (test.exs).
- Stale comments naming the dashboard or `Druzhok.Budget` (config.exs, runtime.exs, llm_format.ex,
  bot_site.ex, `ops/Caddyfile`), and the proxy controller's note that embeddings go to OpenRouter.
- Asset entries in `apps/druzhok_web/.gitignore`; the root `priv/default-page/` duplicate.
- `README.md`: no budgets, no dashboard.

### 3. `/v1/responses`

The OpenRouter Responses passthrough has no calls in 60 days; the last `provider = openrouter` row is
from 2026-09-05, before ruoc. Vision goes through `/v1/chat/completions` (`auxiliary.vision.provider:
custom`). Removed: the route, the controller action and its helpers (`chunk_sse`, `chunk_raw`,
`convert_*`, `meter_image`, `@default_image_model`), `responses_test.exs`, and the parts of
`LlmFormat` only it used (`provider_url`, `provider_key`, `request_url`, `request_headers`,
`extract_cost_cents`, `@fallback_prices`). Then `Settings.openrouter_api_key`, the `openrouter_api_key`
setting key and `OPENROUTER_API_KEY`/`OPENROUTER_API_URL` in runtime.exs. `LlmFormat` keeps
`extract_usage`, `strip_images`, `prompt_preview` (used by `LlmProxy.Ruoc`).

`/v1/audio/speech` (OpenAI TTS, `openai_api_key`) stays: `/voice` uses it (67 calls, last 2026-09-16).
It is the last path recording `cost_cents` in money; moving TTS to ruoc is a separate change.

### 4. Schema

Backup first (`/data/backups/druzhok-pre-legacy-cleanup-<date>.db`). One migration:
- Drop tables `models` (11 rows of an old catalogue), `llm_requests`, `reminders`, `tool_executions`,
  `memory_embeddings`, `allowed_chats` (all 0 rows), `tokens` (1 unassigned row), `pairing_codes`
  (1 expired row).
- Drop columns `instances.api_key` (always null) and `instances.group_sessions_per_user`.
- Delete settings rows `anthropic_api_key`, `nebius_api_key`, `openrouter_api_url`,
  `openrouter_api_key`.

SQLite `DROP COLUMN` needs no table rebuild for these (no index, no constraint). `down` recreates the
tables and columns empty; the data is in the backup. `allow_all_telegram_users` stays (true on
igorhermes: the hermes group-auth bypass).

### 5. Docs and local files

- `docs/superpowers/specs` and `plans`: files describing removed systems (v2/v3, Docker, OpenClaw/v4,
  own-agent features, money budgets, the dashboard) move to `docs/archive/`. Kept in place: the ones
  CLAUDE.md or code cite (systemd host, ruoc migration, web fetch, mnemosyne, referral invites,
  webhook relay, sleep/wake, dashboard removal, this one).
- The mnemosyne plan's references to `ops/embed-model-fetch.sh` and `.embed-model/` get a "retired" note.
- `.embed-model/` (untracked, 465 MB, retired e5-small) is deleted locally.
- CLAUDE.md: `migrate_ruoc` task line, anything naming removed modules.

## Not in this spec (operator decisions)

Inactive rows `hermes2`, `hermes3`, `kot_4dae` (no data dir, no ruoc key), `igor_9bc0_botbotbotbot`
(24 MB data), the row-less `/data/tenants/ctltest`, and `/data/opt/hermes-0.21.0-bak` (605 MB). Deleting
any of them is a separate, explicit request; a data dir is only ever removed through `BotManager.delete`.

## Risks

- A grep misses a dynamic call (`apply/3`, a string-built module). Mitigation: compile with
  `--warnings-as-errors`, full test suite, and on prod a smoke test plus one real message per step.
- Step 1.1 changes what a new bot looks like. Check with the next bot created, or a throwaway one
  created and deleted through the manager bot.
- Step 4 is the only irreversible one; it runs after steps 1–3 are live, from a backup.
