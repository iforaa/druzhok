# Memory System: Local Embeddings, Caching, and Memory Writing

## Context

Druzhok v3's memory search re-embeds all memory chunks via an external API on every search call — expensive and slow. The bot can search memory but can't write to it. There's no mechanism to preserve important context before compaction discards it.

This design adds three tightly coupled features: local embeddings (zero API cost), SQLite embedding cache (avoid redundant computation), and memory writing (daily files + pre-compaction flush).

## 1. Local Embedding Service

### Implementation: `Nx.Serving` directly in supervision tree

Loads `all-MiniLM-L6-v2` (384-dim, ~80MB) via Bumblebee. Started as a named `Nx.Serving` process — no custom GenServer wrapper needed, since `Nx.Serving` already handles batching and request queueing.

**Supervision**: Child of `PiCore.Application`:
```elixir
{Nx.Serving, serving: build_serving(), name: PiCore.Memory.EmbeddingServing, batch_timeout: 50}
```

The `build_serving/0` function loads the model via `Bumblebee.Text.TextEmbedding` and returns an `Nx.Serving` struct.

**API** (module `PiCore.Memory.EmbeddingServer` wrapping `Nx.Serving` calls):
- `embed(text)` → `{:ok, [float]}` — calls `Nx.Serving.batched_run(PiCore.Memory.EmbeddingServing, text)`
- `embed_batch(texts)` → `{:ok, [[float]]}`

**Graceful degradation**: If model download fails at startup or model loading errors, the serving starts in a degraded mode. `embed/1` returns `{:error, :model_unavailable}`, and `Search` falls back to BM25-only (same as current behavior when API embeddings are unavailable).

**Dependencies**: `bumblebee`, `nx` added to `pi_core/mix.exs`. Uses `Nx.BinaryBackend` (pure Elixir, no native deps) — MiniLM-L6-v2 at 80MB is small enough that CPU inference via BinaryBackend is fast enough (~50-100ms per batch). No EXLA/Torchx needed, keeping the build lean.

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

```elixir
@callback get(instance_name :: String.t(), chunk_hash :: String.t()) :: {:ok, [float]} | :miss
@callback put(instance_name :: String.t(), entry :: map()) :: :ok
@callback delete_missing_files(instance_name :: String.t(), current_files :: [String.t()]) :: :ok
```

`delete_missing_files/2` removes all cache entries whose `file` is not in `current_files`. This is cleaner than hash-based stale detection.

### Injection: via opts, same as other behaviours

The cache module is passed through `opts` in `Search.search/3`:

```elixir
Search.search(workspace, query, %{
  instance_name: instance_name,
  embedding_cache: Druzhok.EmbeddingCache,
  ...
})
```

The `MemorySearch` tool extracts `instance_name` from `tool_context` and passes it through. When no cache module is provided, Search skips caching (backward compatible).

### Table: add `model_name` column

| Column | Type | Purpose |
|--------|------|---------|
| `model_name` | string | Embedding model (e.g., `all-MiniLM-L6-v2`) for cache invalidation on model change |

If the model changes, all cached embeddings are invalidated.

### Updated search flow in `PiCore.Memory.Search`

```
read files → chunk → SHA256 hash each chunk
  → lookup hashes in cache (if cache module provided)
  → NEW/CHANGED chunks → embed via EmbeddingServer → store in cache
  → CACHED chunks → use stored vectors
  → embed query via EmbeddingServer (always fresh)
  → cosine similarity scoring (cosine_similarity moves to a utility function)
  → BM25 + vector hybrid merge (unchanged)
```

**Cache cleanup**: Runs after `memory_write` operations and on session reset — NOT on every search. The `delete_missing_files/2` callback compares cached file list against actual workspace files.

## 3. Memory Writing

### 3a. `memory_write` tool (user-initiated)

New tool the bot calls when asked to remember something or when it decides a fact is worth saving.

**Parameters**:
- `content` (string) — what to write
- `file` (string, optional) — target file, defaults to `memory/YYYY-MM-DD.md` (today in instance timezone)

**Path guard**: Writes are confined to the `memory/` subdirectory via `PiCore.Tools.PathGuard`. Any path outside `memory/` is rejected. This prevents the bot from overwriting `AGENTS.md`, `SOUL.md`, or escaping the workspace.

**Behavior**: Appends to target file, creates if needed. Each entry gets a timestamp header:

```markdown
### 14:32

User prefers short responses. Doesn't like emoji.
```

The bot's AGENTS.md guides when to use this tool.

### 3b. Pre-compaction memory flush (automatic)

When compaction is about to discard old messages, it first extracts important context into the daily memory file.

**New opts for `Compaction.maybe_compact/2`**: The opts map is extended with optional fields:
```elixir
%{
  budget: %TokenBudget{},
  llm_fn: fn,
  workspace: "/path/to/workspace",   # NEW — needed for memory flush
  timezone: "Europe/Moscow",          # NEW — needed for daily file naming
  memory_flush: true                  # NEW — enable/disable flush (default false)
}
```

Call sites in `Session.run_prompt/2` and `handle_cast({:set_model, ...})` are updated to pass these fields.

**Flow**:
1. `Compaction.maybe_compact` detects messages exceed history budget
2. If `opts[:memory_flush]` is true, calls `PiCore.Memory.Flush.flush(old_messages, llm_fn, workspace, timezone)`
3. LLM call with system prompt: "Extract important facts, decisions, preferences, and context worth remembering. Write in the same `### HH:MM` format as memory_write entries. Be concise."
4. Response appended to `memory/YYYY-MM-DD.md`
5. Normal compaction proceeds

**Guard**: One flush per compaction cycle — tracked as a local flag within `compact/3` function scope (not persisted in message metadata). If the existing compaction summary has messages that were already flushed (checked via presence of recent entries in today's memory file with matching timestamps), skip the flush.

**Cost**: One extra LLM call per compaction event (rare — only when context fills up).

### 3c. Timezone configuration

**New field**: `timezone` on `instances` table (string, default `"UTC"`). Validated as IANA timezone string (e.g., `"Europe/Moscow"`, `"America/New_York"`) using Elixir's `Calendar.TimeZone` or the `tz` library.

**Bootstrap**: BOOTSTRAP.md prompt asks user for timezone during first conversation. Stored via instance config.

**Dashboard**: Timezone editable in instance settings (dropdown or validated text input).

**Usage**: Both `memory_write` and pre-compaction flush use instance timezone for daily file naming (`memory/YYYY-MM-DD.md`).

## Modified Modules

| Module | Changes |
|--------|---------|
| `PiCore.Memory.Search` | Use EmbeddingServer + cache instead of API; accept instance_name and cache module via opts |
| `PiCore.Memory.Embeddings` | Remove module. Move `cosine_similarity/2` to `PiCore.Memory.VectorMath` utility module |
| `PiCore.Compaction` | Add pre-compaction memory flush step; accept workspace/timezone/memory_flush in opts |
| `PiCore.Session` | Add timezone field; pass workspace/timezone/memory_flush to compaction; add `memory_write` to default_tools |
| `PiCore.Tools.MemorySearch` | Pass instance_name and embedding_cache from tool_context to Search |
| `Druzhok.Instance` | Add `timezone` field to schema |
| `Druzhok.Instance.Sup` | Pass timezone and embedding_cache in session config |

## New Modules

| Module | App | Purpose |
|--------|-----|---------|
| `PiCore.Memory.EmbeddingServer` | pi_core | Thin wrapper around Nx.Serving for local embeddings |
| `PiCore.Memory.VectorMath` | pi_core | `cosine_similarity/2` (extracted from Embeddings) |
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

No EXLA or Torchx — using `Nx.BinaryBackend` (pure Elixir). MiniLM-L6-v2 at 80MB is small enough for CPU inference without native compilation dependencies. Keeps build lean and Docker images small.
