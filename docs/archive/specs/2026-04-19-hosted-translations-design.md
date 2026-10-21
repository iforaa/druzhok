# Hosted Translations Design

## Goal

Move the hermes system-message translation data out of the hermes Docker image and into the druzhok repo, so that editing a Russian translation no longer requires rebuilding a 3 GB image. One-time image rebuild installs a JSON-loader patch; after that, translations are owned by druzhok and injected into each bot container on every start.

## Motivation

Current state (customization #4 in `update-hermes` skill): druzhok patches `gateway/translations.py` into the hermes image with a hard-coded 157-line Python dict of English → Russian strings, plus the `translate_system_message()` function. Any copy change — even a typo fix — means a full hermes image rebuild, compression, rsync to the remote, and `docker load`. That is ~15 minutes of mechanical work for a single string edit.

Translations are pure data. They belong in druzhok, where the rest of the bot configuration already lives, and should be editable without touching the hermes image.

## Architecture

```
druzhok repo                 container volume            hermes process
─────────────                ────────────────            ──────────────
priv/translations.json  ──▶  /opt/data/translations.json  ──▶  gateway/translations.py
(source of truth)            (written by sync_config       (reads at import time)
                              on every bot start)
```

**Direction of data flow:**
1. Developer edits `v4/druzhok/priv/translations.json` in the druzhok repo.
2. Developer restarts the druzhok service (or commits + deploys).
3. On bot container start, druzhok's `Druzhok.Runtime.Hermes.sync_config/2` reads `priv/translations.json` and writes a copy to `data_root/translations.json` (mounted at `/opt/data/translations.json` inside the container).
4. The hermes gateway imports `gateway.translations`, which reads `/opt/data/translations.json` at module-import time and populates its in-memory dict.
5. `translate_system_message(text)` looks up the current language (`HERMES_LANGUAGE` env var, already set by druzhok) and returns the translated string.

## Components

### 1. `v4/druzhok/priv/translations.json`

The canonical translations file. Structure:

```json
{
  "ru": {
    "<english phrase>": "<russian phrase>",
    ...
  }
}
```

Seed content: the existing 43 translated phrases from `gateway/translations.py` on the hermes image. Top-level keys are ISO language codes (only `ru` for now).

### 2. `Druzhok.Runtime.Hermes.sync_translations_file/1`

New private helper in `v4/druzhok/apps/druzhok/lib/druzhok/runtime/hermes.ex`, called from `sync_config/2` on every bot start.

Responsibility:
- Read `priv/translations.json` via `:code.priv_dir(:druzhok)`.
- Write the file verbatim to `Path.join(data_root, "translations.json")`.
- Idempotent — writing the same content on every restart is fine; hermes re-imports the module on each process start.

No-op if the priv file is missing (logs a warning, does not crash). Bots will fall back to English, which is the same behavior as today before customization #4 existed.

### 3. Hermes patch — `gateway/translations.py`

Replace the current 157-line file with ~25 lines:

```python
"""Druzhok downstream: system message translations loaded from JSON."""
import json
import os

_TRANSLATIONS_PATH = os.getenv(
    "HERMES_TRANSLATIONS_PATH",
    "/opt/data/translations.json",
)

try:
    with open(_TRANSLATIONS_PATH, encoding="utf-8") as _f:
        _TRANSLATIONS = json.load(_f)
except (FileNotFoundError, json.JSONDecodeError):
    _TRANSLATIONS = {}


def translate_system_message(text: str) -> str:
    if not text:
        return text
    lang = os.getenv("HERMES_LANGUAGE", "en").lower()
    if lang == "en":
        return text
    translations = _TRANSLATIONS.get(lang)
    if not translations:
        return text
    if text in translations:
        return translations[text]
    result = text
    for en_phrase, translated in translations.items():
        if en_phrase in result:
            result = result.replace(en_phrase, translated)
    return result
```

No changes to the two call sites in `gateway/run.py` — they still `from gateway.translations import translate_system_message as _tr`.

### 4. `update-hermes` skill — Customization #4 rewrite

The skill currently writes the full 157-line `translations.py` into the image as part of the patch re-apply. After this change, it writes the ~25-line loader file. The JSON itself is no longer part of the hermes patch set.

## Data Flow

**On druzhok service start / bot container start:**

```
BotManager.start_instance(instance)
  └─▶ Druzhok.Runtime.Hermes.sync_config(instance, data_root)
        ├─▶ sync_agents_md(...)
        ├─▶ write/patch config.yaml
        └─▶ sync_translations_file(data_root)  ← NEW
              ├─▶ read :code.priv_dir(:druzhok) / "translations.json"
              └─▶ write data_root / "translations.json"
```

**On hermes process start (inside container):**

```
python -m hermes_cli gateway run
  └─▶ imports gateway.translations
        └─▶ reads /opt/data/translations.json
              └─▶ populates module-level _TRANSLATIONS dict

message received
  └─▶ translate_system_message("✨ New session started!")
        └─▶ lookup in _TRANSLATIONS["ru"]
              └─▶ returns "✨ Новая сессия!"
```

## Error Handling

| Failure | Behavior |
|---|---|
| `priv/translations.json` missing in druzhok | Druzhok logs warning, does not write file, bot gets English fallback |
| `priv/translations.json` malformed JSON | Druzhok logs error, does not write file (preserves last good copy on disk if any), bot uses stale-but-valid translations or English |
| `/opt/data/translations.json` missing in container | Hermes `_TRANSLATIONS = {}`, all messages return English |
| `/opt/data/translations.json` malformed JSON | Same as missing — `_TRANSLATIONS = {}`, English fallback |
| `HERMES_LANGUAGE` env var unset | Defaults to `"en"`, returns text unchanged |

All failure modes degrade to English. No crashes, no missing strings.

## Testing

**Unit test** (Elixir): `sync_translations_file/1` writes the priv file to the target data root. Uses a temp dir, no actual container needed.

**Manual smoke test** after deploy:
1. Edit one translation in `priv/translations.json` (e.g., change `"✨ Сессия сброшена! Начинаем с чистого листа."` to something different).
2. `sudo systemctl restart druzhok` on the remote.
3. Send `/new` to a bot.
4. Verify the bot replies with the edited translation.

No hermes unit test — the JSON-load-at-import behavior is trivial and tested by the smoke test end-to-end.

## Migration

1. **Seed `priv/translations.json`**: extract the existing 43 translations from the hermes image's `gateway/translations.py` into the new JSON file (one-time data move).
2. **Implement `sync_translations_file/1`** and wire into `sync_config/2`.
3. **Rebuild hermes image once** with the new ~25-line `translations.py`.
4. **Deploy**: `git push` → remote `git pull` → `sudo systemctl restart druzhok`.
5. **After migration**: editing a translation = edit `priv/translations.json` + `systemctl restart druzhok`. No image rebuild.

Rollback plan: revert the hermes patch in the `update-hermes` skill and rebuild the image with the embedded dict. Druzhok side is no-op (the JSON file is ignored by the old hermes code).

## Out of Scope

- Multi-language support (more than `ru`). The file structure already supports it — add another top-level key — but no UI or detection logic.
- Per-bot translation overrides. All bots share the same `translations.json`.
- Dashboard UI for editing translations. File edit + service restart is fine for now.
- Hot-reload without restart. Hermes loads JSON at module-import time; a code change would require container restart anyway.
