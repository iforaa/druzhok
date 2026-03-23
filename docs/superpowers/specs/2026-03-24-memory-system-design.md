# Memory System: Local Embeddings, Caching, and Memory Writing

## Context

Druzhok v3's memory search re-embeds all memory chunks via an external API on every search call — expensive and slow. The bot can search memory but can't write to it. There's no mechanism to preserve important context before compaction discards it.

This design adds three tightly coupled features: local embeddings (zero API cost), SQLite embedding cache (avoid redundant computation), and memory writing (daily files + pre-compaction flush).

## 1. Local Embedding Service

### Module: `PiCore.Memory.EmbeddingServer` (GenServer)

Loads `all-MiniLM-L6-v2` (384-dim, ~80MB) via Bumblebee at startup. One process shared across all instances.

**Supervision**: Child of `PiCore.Application`, named `PiCore.Memory.EmbeddingServer`.

**API**:
- `embed(text)` → `{:ok, [float]}`
- `embed_batch(texts)` → `{:ok, [[float]]}`

**Internals**: Loads model + tokenizer in `init/1`. Uses `Nx.Serving` for batched inference. Model auto-downloaded on first start, cached in `~/.cache/bumblebee/`.

**Dependencies**: `bumblebee`, `nx`, `exla` added to `pi_core/mix.exs`.

## 2. SQLite Embedding Cache

### Architecture: behaviour in pi_core, implementation in druzhok

Keeps pi_core database-free, following the existing ModelInfo/WorkspaceLoader pattern.

### Table: `memory_embeddings`

| Column | Type | Purpose |
|--------|------|---------|
| `instance_name` | string | Multi-tenant isolation |
| `file` | string | Source file path |
| `chunk_hash` | string | SHA256 of chunk text (cache key) |
| `chunk_text` | text | Chunk content |
| `embedding` | binary | Serialized via `:erlang.term_to_binary` |
| `updated_at` | utc_datetime | Staleness tracking |

**Unique constraint**: `(instance_name, chunk_hash)`

### Behaviour: `PiCore.Memory.EmbeddingCache`

```
@callback get(instance_name, chunk_hash) :: {:ok, [float]} | :miss
@callback put(instance_name, %{file, chunk_hash, chunk_text, embedding}) :: :ok
@callback delete_file(instance_name, file) :: :ok
@callback delete_stale(instance_name, current_hashes) :: :ok
```

### Updated search flow in `PiCore.Memory.Search`

```
read files → chunk → SHA256 hash each chunk
  → lookup hashes in cache
  → NEW/CHANGED chunks → embed via EmbeddingServer → store in cache
  → CACHED chunks → use stored vectors
  → embed query via EmbeddingServer (always fresh)
  → cosine similarity scoring (replaces API-based vector scoring)
  → BM25 + vector hybrid merge (unchanged)
  → delete cache entries for files that no longer exist (cleanup)
```

Cache cleanup runs at the start of each search: compares cached files against actual workspace files, deletes entries for removed files.

## 3. Memory Writing

### 3a. `memory_write` tool (user-initiated)

New tool the bot calls when asked to remember something or when it decides a fact is worth saving.

**Parameters**:
- `content` (string) — what to write
- `file` (string, optional) — target file, defaults to `memory/YYYY-MM-DD.md` (today in instance timezone)

**Behavior**: Appends to target file, creates if needed. Each entry gets a timestamp header:

```markdown
### 14:32

User prefers short responses. Doesn't like emoji.
```

The bot's AGENTS.md guides when to use this tool.

### 3b. Pre-compaction memory flush (automatic)

When compaction is about to discard old messages, it first extracts important context into the daily memory file.

**Flow**:
1. `Compaction.maybe_compact` detects messages exceed history budget
2. Before summarizing, calls `memory_flush(old_messages, llm_fn, workspace, timezone)`
3. LLM call with system prompt: "Extract important facts, decisions, preferences, and context worth remembering. Be concise."
4. Response appended to `memory/YYYY-MM-DD.md`
5. Normal compaction proceeds

**Guard**: One flush per compaction cycle, tracked via `memory_flushed: true` in compaction summary metadata. Skip if already flushed.

**Cost**: One extra LLM call per compaction event (rare — only when context fills up).

### 3c. Timezone configuration

**New field**: `timezone` on `instances` table (string, default `"UTC"`).

**Bootstrap**: BOOTSTRAP.md prompt asks user for timezone during first conversation. Stored via instance config.

**Dashboard**: Timezone editable in instance settings.

**Usage**: Both `memory_write` and pre-compaction flush use instance timezone for daily file naming (`memory/YYYY-MM-DD.md`).

## Modified Modules

| Module | Changes |
|--------|---------|
| `PiCore.Memory.Search` | Use EmbeddingServer + cache instead of API; cleanup stale cache entries |
| `PiCore.Memory.Embeddings` | Replace API calls with EmbeddingServer calls (or remove entirely) |
| `PiCore.Compaction` | Add pre-compaction memory flush step |
| `PiCore.Session` | Pass timezone to compaction for memory flush |
| `Druzhok.Instance` | Add `timezone` field to schema |
| `Druzhok.Instance.Sup` | Pass timezone in session config |

## New Modules

| Module | App | Purpose |
|--------|-----|---------|
| `PiCore.Memory.EmbeddingServer` | pi_core | Bumblebee GenServer for local embeddings |
| `PiCore.Memory.EmbeddingCache` | pi_core | Behaviour for embedding cache |
| `Druzhok.EmbeddingCache` | druzhok | DB-backed cache implementation |
| `PiCore.Memory.Flush` | pi_core | Pre-compaction memory flush logic |
| `PiCore.Tools.MemoryWrite` | pi_core | `memory_write` tool |

## New Files

| File | Purpose |
|------|---------|
| Migration: `add_memory_embeddings` | Create `memory_embeddings` table |
| Migration: `add_timezone_to_instances` | Add `timezone` column |

## Dependencies

Add to `pi_core/mix.exs`:
- `{:bumblebee, "~> 0.6"}`
- `{:nx, "~> 0.9"}`
- `{:exla, "~> 0.9"}` (XLA backend for Nx)
