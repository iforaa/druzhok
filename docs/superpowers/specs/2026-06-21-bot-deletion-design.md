# Full bot deletion + superbot delete button

**Date:** 2026-06-21
**Status:** Approved

## Context

The superbot (`Druzhok.ManagerBot`) lets users create personal bots but has **no way to delete one**. `BotManager.delete/1` exists (console-only, no callers) and stops the container, releases the Telegram token, and deletes the DB row — but it **leaves the entire on-disk data directory behind** (`/home/igor/druzhok-data/v4-instances/<name>/`: `config.yaml`, `SOUL.md`, `.env`, memory, conversation history, caches, logs — ~12 MB+). Users need a self-service way to **fully** delete a bot (including all data) from within the superbot. Per user decision, deletion is a **full, irreversible wipe**.

## Design

### 1. Delete primitive — enhance `BotManager.delete/1`

Single shared primitive (also reusable by the dashboard later). New sequence:

1. `stop(name)` — existing: LogWatcher stop, `docker update --restart=no` + `docker rm -f`, HealthMonitor unregister, mark inactive.
2. **`File.rm_rf!(data_root)`** — NEW. `data_root = Path.dirname(instance.workspace)`. Guarded by `safe_to_wipe?/1`.
3. `TokenPool.release(instance.id)` — token returns to pool.
4. `Repo.delete(instance)` — DB row removed.

Returns `:ok | {:error, reason}`; best-effort, logs each step.

**Safety guard `safe_to_wipe?/1`** refuses to `rm -rf` when the path is `nil`, `""`, `"/"`, or not located under the configured data root (`DRUZHOK_DATA_ROOT`, falling back to the same default used in `create/2`). This makes a malformed/blank `instance.workspace` unable to wipe anything unexpected.

### 2. Superbot UI — button + two-step confirm

- `Onboarding.my_bots_message/1`: each bot row gains a `🗑` callback button beside the existing `💬 @handle` URL button → `callback_data: "del:<id>"` (numeric instance id; well within Telegram's 64-byte limit). `build_url_keyboard/1` already renders mixed url+callback rows.
- New presentation helpers in `Onboarding`: `delete_confirm(id, handle)` → `{text, rows}` with `[✅ Да, удалить → "delyes:<id>"]` / `[❌ Отмена → "delno"]`; `delete_done(handle)`; `delete_cancelled()`.
- New callback handling in `ManagerBot.process_update` (callback branch), intercepted **before** the onboarding dispatch by `callback_data` prefix:
  - `del:<id>` → verify ownership → edit message to the confirm prompt.
  - `delyes:<id>` → re-verify ownership → run `BotManager.delete` in a `Task` (try/rescue) → edit message to `delete_done` (or error).
  - `delno` → edit message to `delete_cancelled`.

The flow is **stateless**: it uses the callback's own `message_id` for edits, so no onboarding session is involved.

### 3. Authorization

Ownership (`instance.owner_telegram_id == cb["from"]["id"]`) is checked on **both** `del:` and `delyes:`. A crafted callback for another user's bot → `answer_callback_query` "Это не твой бот", no action. Missing instance → "Бот не найден."

## Error handling

- Path-guarded wipe; `rm_rf` failure logged, surfaced as `{:error, _}`.
- Provisioning-style `Task` try/rescue → user sees "Ошибка удаления, попробуй ещё раз."
- Deletion runs async so the poll loop isn't blocked by `docker rm -f`.

## Testing

- **Unit:** `safe_to_wipe?/1` accepts a path under the data root and rejects `nil`/`""`/`"/"`/outside-root; `Onboarding.my_bots_message/1` emits a `del:<id>` button per bot; `delete_confirm/2` yields `delyes:`/`delno` buttons.
- **Manual (throwaway bot):** delete via superbot → confirm container gone (`docker ps`), data dir gone (`ls /v4-instances`), token back in pool, DB row gone; verify a non-owner callback is rejected.

## Out of scope

Dashboard delete button (the enhanced `BotManager.delete/1` is the shared primitive a future dashboard button would call). The per-user bot limit already enforced elsewhere is unaffected.
