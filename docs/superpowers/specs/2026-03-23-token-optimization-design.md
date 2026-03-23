# Token Optimization System for Druzhok v3

## Context

Druzhok v3 runs bots on mixed model sizes (8K–200K context windows) with varied usage patterns (short chats to long coding sessions). The current system has no token awareness — workspace files load in full, compaction triggers on message count (40), tool results are fixed at 8KB, and reasoning content replays in full. This wastes tokens, which drives up cost (the primary pain point).

OpenClaw and pi-mono have battle-tested patterns for token efficiency. This design adapts their best ideas into a unified budget system for v3.

## Design Principles

1. **All hyperparameters configurable through the web dashboard** — never hardcoded in application code. Budget ratios, model metadata, per-file caps — everything lives in the database with a settings UI.
2. **Proportional to context window** — budgets adapt automatically per model. A bot on 8K gets aggressive caps; one on 200K relaxes them.
3. **Lazy over eager** — load content on demand (skills, memory) rather than upfront.
4. **Preserve what matters** — head+tail truncation keeps beginnings (structure/rules) and ends (errors/recent additions). Never blind head-only truncation.
5. **Clean app boundaries** — `pi_core` stays database-free. All DB access lives in `druzhok` and is injected into `pi_core` via behaviours/callbacks, following the existing `WorkspaceLoader` pattern.

## Architecture Overview

```
Context Window (model-specific, user-configurable)
├── System Prompt Budget (default 15%)
│   ├── Identity: IDENTITY.md + SOUL.md (highest priority, never truncated unless huge)
│   ├── Instructions: AGENTS.md, USER.md, BOOTSTRAP.md (per-file cap, head+tail truncation)
│   └── Skills Catalog: tiered format (full → compact → minimal)
├── Tool Definitions Budget (default 5%)
│   └── JSON schemas for all registered tools (fixed cost per session)
├── Conversation History Budget (default 50%)
│   ├── Compaction summary (if exists, capped at 15% of history budget)
│   ├── Recent messages (token-counted)
│   └── Reasoning stripped on replay
├── Tool Results Budget (default 20%)
│   ├── Per-result cap (proportional)
│   ├── Old results compacted in-place
│   └── Head+tail truncation
└── Response Reserve (default 10%)
```

## 1. Token Estimation

### Module: `PiCore.TokenEstimator`

Foundation for all budget decisions. Uses `byte_size / 4` heuristic. Using byte size rather than character count makes this more conservative for non-Latin text (Russian/Cyrillic, which Druzhok uses heavily — UTF-8 Cyrillic is 2 bytes per char). The divisor is configurable via dashboard setting `token_estimation_divisor` (default: 4).

### Functions

- `estimate(text)` — estimated token count for a string
- `estimate_message(message)` — handles `Loop.Message`, counts content + tool call arguments + tool name overhead
- `estimate_messages(messages)` — sums a list
- `estimate_tools(tools)` — tokens for tool definitions (name + description + parameter schema JSON)

### Special cases

- Reasoning/thinking content in assistant messages: counted separately (stripped on replay)
- Tool results: counted including truncation markers
- Nil/empty content: 0

## 2. Model Metadata Registry

### Database-backed, dashboard-editable

Extend the existing `models` table (migration `20260322000002`) with new columns:

| Column | Type | Purpose |
|--------|------|---------|
| `context_window` | integer | Context window in tokens |
| `supports_reasoning` | boolean | Has reasoning/thinking output |
| `supports_tools` | boolean | Supports tool/function calling |

Existing columns (`model_id`, `label`, `position`) are preserved.

### Architecture: behaviour in pi_core, implementation in druzhok

`pi_core` stays database-free. The lookup is injected via a behaviour:

```elixir
# In pi_core
defmodule PiCore.ModelInfo do
  @callback context_window(model_name :: String.t()) :: pos_integer()
  @callback supports_reasoning?(model_name :: String.t()) :: boolean()
end

# In druzhok
defmodule Druzhok.ModelInfo do
  @behaviour PiCore.ModelInfo
  # Queries DB, strips provider prefix, fuzzy matches, falls back to default
end
```

Injected into `PiCore.Session` via opts, same pattern as `workspace_loader`.

### Lookup logic (in `Druzhok.ModelInfo`)

1. Strip provider prefix (`nebius/deepseek-ai/DeepSeek-R1` → `DeepSeek-R1`)
2. Exact match against `models.model_id`
3. Fuzzy/prefix match if no exact hit
4. Fall back to `default_context_window` setting (default: 32K)

### Caching

ETS cache with short TTL. Invalidated via `Phoenix.PubSub` broadcast `{:models_updated}` on dashboard save.

### Seeding

Common models seeded on first run (Claude, GPT-4o, DeepSeek, etc.). Fully user-editable after that.

## 3. System Prompt Budget

### Module: `PiCore.PromptBudget`

Replaces `WorkspaceLoader.Default` with budget-aware prompt construction.

### Budget: configurable ratio of context window (default 15%)

### Sub-layers with priority ordering

**1. Identity (highest priority)**

`IDENTITY.md` + `SOUL.md` — loaded in full. If somehow larger than 20% of system prompt budget, head+tail truncated (first 70%, last 20%, ellipsis marker between).

**2. Instructions (high priority)**

`AGENTS.md`, `USER.md` (DM only), `BOOTSTRAP.md` (first run only). Per-file cap: 40% of system prompt budget. Head+tail truncation when exceeded (70/20 split — preserves beginning rules and recent additions at the end).

**3. Skills catalog (lowest priority, most compressible)**

Three format tiers, selected by fallback chain against remaining budget:
- **Full**: `- **skill-name**: description (path)`
- **Compact**: `- skill-name (path)`
- **Minimal**: `- skill-name`

If even minimal doesn't fit, truncate the list by priority.

Path compaction: replace workspace absolute path with `./` in skill listings.

**4. Model info line**

Always included (tiny). Current `append_model_info/2` behavior preserved.

### Key function

`build_system_prompt(workspace, opts)` where opts includes `budget_tokens`, `group`, `skills`, `read_fn`. Returns `{prompt_string, token_estimate}`.

### Head+tail truncation helper

`PiCore.Truncate.head_tail(text, max_chars, head_ratio \\ 0.7, tail_ratio \\ 0.2)`

Preserves first `head_ratio` and last `tail_ratio` of allowed size. The remaining 10% is reserved for the truncation marker itself. The marker is:

```
... [truncated — original was N chars, showing first/last portions] ...
```

**Edge cases**:
- If text is within 10% of the cap, include it in full (avoid truncating for negligible savings).
- Minimum `max_chars` of 200 — below this, truncation does more harm than good.
- Never split mid-line: snap head and tail boundaries to the nearest newline.

## 3b. Tool Definitions Budget

Tool definitions (JSON schemas) are sent with every LLM call. With 9 default tools, this is 2,000–4,000 tokens — significant on small models.

### Budget: configurable ratio of context window (default 5%)

This is a **fixed cost** per session — it doesn't change between iterations. The budget is checked at session init: `TokenEstimator.estimate_tools(tools)` must fit within the allocation. If it doesn't, log a warning — this means the model is too small for the registered tool set.

Future optimization: tool subsetting per model size (e.g., drop `grep` and `find` on 8K models, keep only `bash` + `read` + `write`). Not in scope for this design but the budget makes the problem visible.

### MEMORY.md handling

`MEMORY.md` is NOT loaded into the system prompt. It is accessed lazily via the `memory_search` tool, which returns results as tool results (falling under the tool result budget). This aligns with the "lazy over eager" principle and prevents large memory files from consuming system prompt budget.

## 4. Conversation History Budget

### Budget: configurable ratio of context window (default 55%)

### 4a. Reasoning stripping (always applied, free win)

Before building `llm_messages` in the Loop, strip `reasoning_content` / thinking blocks from all previous assistant messages. The canonical `state.messages` keeps reasoning intact for persistence and debugging. The LLM never sees old reasoning.

Estimated savings: 20–40% per reasoning model turn.

### 4b. Token-based compaction trigger

Replace `length(messages) > 40` with `TokenEstimator.estimate_messages(messages) > history_budget`.

Short-message conversations can go hundreds of exchanges. Heavy tool-use conversations compact much sooner.

`keep_recent` becomes token-based: keep the most recent messages fitting within 30% of the history budget (instead of fixed 10 messages). **Never split a tool-call/tool-result sequence** — always keep complete turns. If one turn exceeds 30%, expand the keep window for that turn and let the summary absorb the cost.

### 4c. Iterative summarization

When compacting, if a previous compaction summary exists, use an **update prompt** that merges new information into the existing summary rather than regenerating from scratch.

**Summary message identification**: Compaction summaries carry metadata `%{type: :compaction_summary, version: N}` so they can be reliably found in the message list. The version increments on each compaction cycle.

**Summary size cap**: The compaction summary is capped at 15% of the history budget. If the summary grows beyond this after an iterative merge, it is truncated using head+tail. This prevents unbounded summary growth over many compaction cycles.

**Initial compaction prompt** (no existing summary):

```
Summarize the following conversation concisely. Use this structure:

## Goal
## Progress
## Key Decisions
## Files Read/Modified
## Next Steps

Preserve UUIDs, file paths, API keys, URLs, and exact identifiers.

<conversation>
{serialized_messages}
</conversation>
```

**Iterative update prompt** (existing summary present):

```
Update this conversation summary with the new messages below.
Merge new information into the existing structure. Do not repeat what is already captured.

<existing-summary>
{previous_summary}
</existing-summary>

<new-messages>
{serialized_new_messages}
</new-messages>
```

**File operation tracking**: `<read-files>` and `<modified-files>` are extracted from tool call messages by matching tool names (`read` → read-files, `write`/`edit` → modified-files) and pulling the file path argument. These lists are appended to the summary and carried forward across compactions.

### Module changes

- `PiCore.Compaction` — rewrite `maybe_compact/2` to use token budgets, add iterative update path
- `PiCore.Loop` — add `transform_messages/1` before LLM call

## 5. Tool Result Budget

### Budget: configurable ratio of context window (default 20%)

### 5a. Per-result cap (at execution time)

Replace fixed 8KB with proportional cap: **max 30% of tool result budget per individual result**.

For 128K model: ~7.6K tokens (~30K chars). For 8K model: ~480 tokens (~1.9K chars).

**Head+tail truncation**: first 70% of cap + last 20%, with marker. Preserves output structure and error messages at the end.

### 5b. In-place compaction of old results (before LLM call)

Part of `transform_messages/1` in the Loop. Before each LLM call:

1. Calculate total tool result tokens in history
2. If over budget, walk oldest to newest
3. Replace old tool results with `"[Tool output compacted — N bytes removed]"`
4. Stop once under budget
5. Never compact results from the current Loop iteration

### 5c. Pre-persistence guard

`SessionStore.sanitize_for_persistence(messages, budget)` — called by Session before `save/append`. Caps any tool result exceeding 2x the per-result cap using head+tail truncation. Prevents unbounded session file growth and ensures reloaded sessions don't blow the budget.

## 6. Skill System Integration

Lightweight hook point for the upcoming skill system.

### Skill prompt allocation

Lives within the system prompt budget. After identity + instructions, remainder goes to skills. The three tiers (Section 3) are the main compression mechanism.

### Lazy loading

Skills are never loaded into the system prompt body. Only the catalog (names/descriptions) is included. The bot uses `read` tool to load a skill's `SKILL.md` on demand. A bot with 50 skills doesn't pay 50x prompt cost.

### Skill content as tool result

When a skill IS loaded via `read`, it falls under the tool result budget. No special handling — per-result cap applies naturally.

### Interface contract

The skill system provides `list_skills(workspace) :: [{name, description, path}]`. `PromptBudget` consumes this list and formats within remaining system prompt budget.

## 7. Budget Orchestration

### TokenBudget struct

```elixir
%TokenBudget{
  context_window: 128_000,
  system_prompt: 19_200,    # 15%
  tool_definitions: 6_400,  # 5%
  history: 64_000,          # 50%
  tool_results: 25_600,     # 20%
  response_reserve: 12_800  # 10%
}
```

Computed at session init and on model change. Stored in `PiCore.Session` state. Passed to Loop, Compaction, PromptBudget.

### Configuration

All ratios stored in DB, editable from dashboard:

- `system_prompt_budget_ratio` (default 0.15)
- `tool_definitions_budget_ratio` (default 0.05)
- `history_budget_ratio` (default 0.50)
- `tool_result_budget_ratio` (default 0.20)
- `response_reserve_ratio` (default 0.10)
- `default_context_window` (default 32,000)
- `token_estimation_divisor` (default 4)

Per-instance overrides possible (e.g., a coding bot gets `tool_result_budget_ratio: 0.30`).

### Data flow

```
Session.init/1
  ├── resolve context_window (instance config > model_profiles DB > default setting)
  ├── TokenBudget.compute(context_window, ratios_from_db)
  ├── PromptBudget.build_system_prompt(workspace, budget.system_prompt, ...)
  └── store budget in state

Session.run_prompt/2
  ├── Compaction.maybe_compact(messages, budget.history)
  └── Loop.run(messages, budget, ...)
        ├── transform_messages(messages, budget)
        │   ├── strip reasoning from old assistant messages
        │   └── compact old tool results if over budget.tool_results
        ├── truncate_output(text, budget)  # per-result cap
        └── LLM call with budget-aware context
```

### Model change handling

When `Session.handle_cast({:set_model, ...})` fires:

1. Recompute `TokenBudget` from the new model's context window
2. Rebuild system prompt via `PromptBudget` with new budget
3. Run `Compaction.maybe_compact/2` immediately — if switching from 128K to 8K, existing history may exceed the new budget
4. Store updated budget in state

This ensures mid-session model switches don't cause context overflow on the next LLM call.

### Response reserve

The 10% response reserve is implicitly enforced: the other four buckets total 90%, so 10% is always available for the model's output. No explicit enforcement needed — it's a design constraint, not runtime logic.

### Safety net

If after all budgeting the total still exceeds the context window, a final guard in `Loop` before the LLM call drops the oldest non-summary messages until it fits. Logs a warning when this triggers.

## New Modules Summary

| Module | App | Purpose |
|--------|-----|---------|
| `PiCore.TokenEstimator` | pi_core | byte_size/4 estimation for strings, messages, tools |
| `PiCore.TokenBudget` | pi_core | Compute and hold per-session budget allocations |
| `PiCore.PromptBudget` | pi_core | Budget-aware system prompt construction |
| `PiCore.Truncate` | pi_core | Head+tail truncation helper |
| `PiCore.ModelInfo` | pi_core | Behaviour for model metadata lookup |
| `Druzhok.ModelInfo` | druzhok | DB-backed implementation with ETS cache |
| `DruzhokWeb.ModelProfileLive` | druzhok_web | Dashboard page for model profiles CRUD |
| `DruzhokWeb.SettingsLive` | druzhok_web | Dashboard page for budget ratio settings |

## Modified Modules

| Module | Changes |
|--------|---------|
| `PiCore.Session` | Add `budget` field, pass to Loop/Compaction |
| `PiCore.Loop` | Add `transform_messages/1`, context-aware `truncate_output/1` |
| `PiCore.Compaction` | Token-based trigger, iterative summarization, structured summaries |
| `PiCore.WorkspaceLoader.Default` | Delegate to `PromptBudget` |
| `PiCore.SessionStore` | Pre-persistence size guard |
| `PiCore.Config` | Read budget ratios from DB instead of hardcoded defaults |
