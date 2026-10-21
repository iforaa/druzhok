# Session Persistence

## Context

Session messages live only in GenServer RAM. Every deploy, idle timeout, or crash loses all conversation history. The `SessionStore` module exists with save/load/append functions but is never called from `Session` (except `clear` on `/reset`). GroupBuffer (ETS) is ephemeral by design and stays unchanged.

## Design

### 1. Per-chat session files

File layout: `workspace/sessions/<chat_id>.jsonl`

Each chat gets its own JSONL file. One JSON object per line, one line per message.

```
workspace/
├── sessions/
│   ├── 123456789.jsonl
│   ├── -1002273542926.jsonl
│   └── -1001234567890.jsonl
├── AGENTS.md
├── memory/
└── skills/
```

File cap: 500 messages max. When saving, keep only the most recent 500.

### 2. Session lifecycle

**On init** — load existing messages:
```
Session.init
  → SessionStore.load(workspace, chat_id)
  → state.messages = loaded messages (0 to 500)
```

**After each completed turn** — append new messages:
```
handle_info({ref, {:ok, new_messages}})
  → state.messages = state.messages ++ new_messages
  → SessionStore.append_many(workspace, chat_id, new_messages)
```

**After compaction** — overwrite with compacted state:
```
Compaction runs → [summary] + [recent messages]
  → SessionStore.save(workspace, chat_id, compacted_messages)
  (full rewrite, enforces 500 cap)
```

**On /reset** — delete the file:
```
SessionStore.clear(workspace, chat_id)
```

**GroupBuffer** — unchanged, stays ETS, ephemeral by design.

### 3. SessionStore API

| Function | Signature | Behavior |
|----------|-----------|----------|
| `save` | `save(workspace, chat_id, messages)` | Overwrite file, enforce 500 cap |
| `append_many` | `append_many(workspace, chat_id, messages)` | Append messages to file |
| `load` | `load(workspace, chat_id)` | Read file, return list of maps |
| `clear` | `clear(workspace, chat_id)` | Delete file |

File path: `Path.join([workspace, "sessions", "#{chat_id}.jsonl"])`

`sessions/` directory created on first write. Messages stored as JSON maps (not structs). The Loop already handles both.

## Modified Modules

| Module | Changes |
|--------|---------|
| `PiCore.SessionStore` | Add chat_id to all functions, per-chat files, 500 cap, append_many |
| `PiCore.Session` | Load on init, append after turn, save after compaction, pass chat_id to clear |
