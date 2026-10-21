# Removing the dashboard (2026-10-21)

Status: done (steps 1–3, 2026-10-21). Item 7 of the review plan ("UI freeze") became removal: the operator is the only
dashboard user (one `users` row, `admin`) and does not use it. Every remaining operator action moves to the
CLI; Phoenix stays for the proxy, the Telegram webhook, `/internal/fetch` and the BotSite plug.

## Steps

One step per commit, each deployed and smoke-tested (`ops/smoke.sh`) before the next.

1. **Read-only views out.** Deleted `/usage`, `/errors`, the bot tabs logs, files, usage and errors, the
   unreferenced `SecurityTab` and `SkillsTab`, and `Druzhok.SqliteBrowser` with the `Usage`/`CrashLog`
   readers only they used. Replacements: `journalctl -u druzhok`, `sudo druzhok-ctl logs <bot>`,
   `sudo sqlite3 /data/druzhok/druzhok.db` (`usage_logs`, `crash_logs`), files over SSH.
2. **Settings into the core, then a CLI.** The bot settings tab knows which fields need a restart
   (memory provider, image generation, mention-only…) and which do not (sleep). That moves into
   `Druzhok.BotSettings.update(name, attrs)`, which writes the row and calls `BotManager.restart` when a
   field needs it. On top: `ops/druzhok-run.sh`-friendly functions, or a `mix druzhok.bot` task, for
   `show`, `set key=value…`, `start`, `stop`, approve/remove users and pairings, `migrate_to_ruoc`, and
   the global `Druzhok.Settings` keys. Creating bots stays with the manager bot.
   Built as `Druzhok.CLI` behind `sudo ops/druzhok <command>` (prod: `druzhok-run.sh`'s env and caps, logs
   at warning) and `mix druzhok <command>` (dev). A restart field restarts only a running bot: the tab
   restarted any bot, which started a stopped one. Secrets are masked in `show`/`settings`; `key=-` reads
   the value from stdin.
3. **Settings pages and the shell out.** `DashboardLive`, `SettingsLive`, `SettingsTab`, `LoginLive`,
   auth (`users`, `AuthController`, `LiveAuth`, plugs), LiveView, the assets pipeline (esbuild,
   Tailwind) and their deps; the `/` routes. Done: also `Druzhok.User` with `bcrypt_elixir` and the
   seeds file (a hard-coded admin password), `priv/static` and `cache_static_manifest` (the "could not
   find static manifest" error at every start), and `Druzhok.ErrorLogger`/`CrashLog`: errors stay in the
   journal. Migrations `20261022000002` and `…03` drop `users` and `crash_logs`. `Druzhok.Events` stays (PubSub
   broadcasts with no subscriber; cheap).

## Not changed

The manager bot (tenants' interface), the proxy endpoints, the webhook relay, the lifecycle controller.
