# Panel: editable pages

Date: 2026-10-31. Status: draft, updated after review round 1. Repo: druzhok. No migration, no hermes fork patch.

## Goal

The owner asked that the panel's pages become editable. Today they are read only.

## Scope

| Page | File | Editable | Limit, code points | When the bot uses it |
|---|---|---|---|---|
| Характер | `SOUL.md` | yes, not blank | 20,000 (`CONTEXT_FILE_MAX_CHARS`) | after `/new` or the chat's next compaction |
| Заметки бота | `memories/MEMORY.md` | yes | 2,200 (`memory_char_limit`) | after `/new` or compaction |
| О вас | `memories/USER.md` | yes | 1,375 (`user_char_limit`) | after `/new` or compaction |
| Мои навыки | `skills/…/SKILL.md` | yes, `name` unchanged | 100,000 (`MAX_SKILL_CONTENT_CHARS`) | body at next use; description after `/new` or compaction |
| Системные навыки | | no: an edit stops hermes updating that skill (`user_modified`) | | |
| Задачи, Сайт | | not in this spec | | |

Read this way because «pages» reads as the text pages the panel opens. Tasks live in JSON and need their own design.

An ongoing chat reuses its stored system prompt, so no edit of these files reaches it at once. The page says so after a save:
«Бот учтёт это в новом разговоре: отправьте ему /new». No hermes change or forced prompt rebuild.

## Server

Routes, through `PanelAuth` (owner, rate limit):

    POST /app/api/files/:kind              {"text": "...", "base_sha256": "..." | null}
    POST /app/api/skills/:name             same body
    POST /app/api/skills/:category/:name   same body

`GET` of these also returns `sha256` (of the whole file), `editable`, and `limit` where there is one. "No file" means
`File.lstat` returned `:enoent`, as `Voice.current/2` defines it. That gives `{"text": "", "sha256": null, "editable": true}` for
Заметки and О вас. Anything else unreadable, a truncated read and a system skill are `editable: false`. Invalid UTF-8 stays 422 `not_text`, shown in place of the file.

Writes need init data under **1 hour** old, else 401 `init_stale`: these files instruct the bot, so a replayed init data should
not be good for 24 hours, but delete's 10 minutes would throw away someone's typing.

### The save runs as the bot's own user

`TenantFiles.write/4` must not be used here. It checks directories by path and then renames by path, with druzhok's
CAP_DAC_OVERRIDE, so a bot swapping `memories` for a symlink between the two could make a save land in another tenant. Running as
the bot's uid limits any swap to what the bot could write itself, as `Panel.Lister` does for listings. It also lets the save hold
hermes's locks and use hermes's own checks instead of copies.

New `Druzhok.Panel.Editor`, inside `:global.trans` per bot and file:

1. Refuse up front, without running anything: body not a string, or over 512 KiB; system skill or unknown path (404, using the
   existing `skills_scan` lookup).
2. Hand over the input. `System.cmd` has no way to close stdin, and argv is limited and visible in `ps`. So write JSON
   `{target, kind, base_sha256, text, limit}` to `<tenant parent>/.panel-save-<random>`: prepared in the staging dir, owned by the bot's
   uid, mode 0400, renamed into place. The parent is root's, so the bot cannot swap the path, and other bots cannot read the file.
   Removed after the run, and any left over are removed at boot.
3. Run `Druzhok.Host.exec(name, [python, "-I", script, path])`, with a 60 s limit. Dev and test run it directly, with a config
   hook for a stub as `:panel_lister` has. `exec` neither starts nor wakes the bot.
4. Map its one line of JSON to the answer. Output is treated as untrusted: any other output is 500 `save_failed`.

The script's source is `apps/druzhok/priv/panel-save/save.py`. It runs from `/usr/local/lib/druzhok/panel-save.py`, config key
`:panel_save_script`, root-owned mode 0644 so a bot can read but not change it. `ops/bootstrap.sh` and the deploy recipe in
`CLAUDE.md` both run `install -m 0644 -o root` on every deploy, including a panel-only one that changes this file; a copy that still
differs is an error in druzhok's log at boot and fails `ops/smoke.sh`. `save.py --check` imports every hermes name it uses and touches no file; `ops/smoke.sh` runs it through
`druzhok-ctl exec`. `-I` keeps the bot's workspace off `sys.path`; it adds only the hermes install dir. In order:

1. Takes the lock: `MemoryStore._file_lock` for memory, hermes's skill lock for a skill. `SOUL.md` has none.
2. Valid UTF-8, no NUL, within the limit: else `too_long` (with `limit`) or `invalid_text`.
3. `SOUL.md` not blank: else `empty_soul`.
4. Memory: runs `_scan_memory_content` on each `§` entry, since hermes replaces a match with a `[BLOCKED]` notice at load. A match
   is `blocked_entry` with the entry's first 60 characters.
5. Skill: runs `_validate_frontmatter`, and the parsed `name` must equal the current one: else `invalid_skill`.
6. Hash check under the lock: `lstat` absent = null. Mismatch is `file_changed`, nothing written.
7. Copies the current text to `<file>.panel-bak`, one generation. If that fails, nothing is written.
8. `utils.atomic_write_text`. Prints `{"sha256", "modified_at"}`.

Errors: 422 for checks, 409 `file_changed`, 500 `save_failed`. Answers carry `cache-control: no-store`. The script imports private
hermes names: any import failure is `save_failed`, so it fails closed, and the `--check` in `ops/smoke.sh` lets `update-hermes`
catch a rename. A timed-out run may still finish; the page's next save then gets `file_changed`, which is safe.

A save neither wakes nor restarts the bot and does not touch `settings_seq`. `Panel` puts each limit in the hand-over: the
memory ones from `Runtime.Hermes.memory_limits/0`, the same numbers it writes into `config.yaml`.

## Known interactions

- **`SOUL.md`:** `Voice.sync_soul/2` leaves a file it did not write. After an owner edit the bot no longer gets the template's
  updates or a Telegram rename there. Accepted; no «reset» button here.
- **`SOUL.md` race:** it has no lock. If the bot or `sync_soul` writes in the milliseconds between the hash check and the rename, one
  side's change is lost and the backup does not hold it. Accepted for this file only.
- **Drift guard:** hermes refuses to rewrite a store holding one entry larger than the whole limit. The limit keeps a save from
  causing it. A file already over the limit must be cut down to save.
- **`§`:** the editor shows raw text with the hint «Знак § разделяет записи». Removing one merges two entries, which is harmless.
- **Mnemosyne:** long memory is not in these files. Deleting a line here does not delete what it recalls. The editor says so on
  those bots.
- **Existing `TenantFiles.write/4` callers** run in start sync and keep the same swap weakness. Not changed here; worth its own fix.

## Page

`TextView` gains «Изменить» when `editable`. The editor is a full-width `textarea`, a counter when there is a limit, and «Сохранить»
and «Отмена». A save can take several seconds, so the button shows progress.

- While editing, the tab bar is hidden and, with unsaved text, `enableClosingConfirmation` is on and Telegram's back button asks
  through `confirmDialog`.
- `file_changed` keeps the owner's text and offers «Показать новую версию», which replaces it after a confirm.
- `init_stale` keeps the text and offers «Скопировать», since reopening the panel loses it.
- `blocked_entry` shows the entry's start: «Бот не примет эту запись. Уберите просьбы отправить что-то по ссылке, ключи доступа и скрытые символы».
- After a save, `invalidate("files")` and return to the read view with the `/new` note.
- New `explain()` cases for each error. The Заметки and О вас rows open even when the file is missing.

## Docs

- `CLAUDE.md`, Bot panel paragraph: pages are no longer read only; the routes, `Panel.Editor`, the save script and its install step, `.panel-bak`.
- `memory.tsx` header; `voice.ex:31` («re-reads it on every message» is wrong).

## Tests

- `panel_api_test.exs` with a stub: each route, error mapping, garbage output is 500, non-owner, init data over an hour, system skill 404, bot not woken, hand-over file removed.
- Script tests, run against the hermes checkout: each check above; stale hash leaves the file; unclosed front matter, closing fence at end of file, empty body; a name change; a U+200D entry; a symlinked target or parent stays within the bot's own reach; a wrong-owner file is refused rather than treated as absent; backup written and replaced; a held memory lock delays the save.
- `sync_soul` leaves a panel-edited soul alone.

## Not doing

Editing tasks, the site, or system skills. Version history or undo in the page. Reset to default. Markdown toolbar. Forcing a prompt rebuild.
