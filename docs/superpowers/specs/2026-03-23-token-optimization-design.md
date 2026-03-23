# Token Optimization System for Druzhok v3

## Context

Druzhok v3 runs bots on mixed model sizes (8K–200K context windows) with varied usage patterns (short chats to long coding sessions). The current system has no token awareness — workspace files load in full, compaction triggers on message count (40), tool results are fixed at 8KB, and reasoning content replays in full. This wastes tokens, which drives up cost (the primary pain point).

OpenClaw and pi-mono have battle-tested patterns for token efficiency. This design adapts their best ideas into a unified budget system for v3.

## Design Principles

1. **All hyperparameters configurable through the web dashboard** — never hardcoded in application code. Budget ratios, model metadata, per-file caps — everything lives in the database with a settings UI.
2. **Proportional to context window** — budgets adapt automatically per model. A bot on 8K gets aggressive caps; one on 200K relaxes them.
3. **Lazy over eager** — load content on demand (skills, memory) rather than upfront.
4. **Preserve what matters** — head+tail truncation keeps beginnings (structure/rules) and ends (errors/recent additions). Never blind head-only truncation.

## Architecture Overview

```
Context Window (model-specific, user-configurable)
├── System Prompt Budget (default 15%)
│   ├── Identity: IDENTITY.md + SOUL.md (highest priority, never truncated unless huge)
│   ├── Instructions: AGENTS.md, USER.md, BOOTSTRAP.md (per-file cap, head+tail truncation)
│   └── Skills Catalog: tiered format (full → compact → minimal)
├── Conversation History Budget (default 55%)
│   ├── Compaction summary (if exists)
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

Foundation for all budget decisions. Uses `chars / 4` heuristic (same as pi-mono — conservative, slightly overestimates).

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

Model metadata lives in SQLite via Ecto as a `model_profiles` table:

| Column | Type | Purpose |
|--------|------|---------|
| `name` | string | Model identifier (e.g., `claude-3-5-sonnet`) |
| `context_window` | integer | Context window in tokens |
| `supports_reasoning` | boolean | Has reasoning/thinking output |
| `supports_tools` | boolean | Supports tool/function calling |

### Lookup: `PiCore.ModelInfo.context_window(model_name)`

1. Strip provider prefix (`nebius/deepseek-ai/DeepSeek-R1` → `DeepSeek-R1`)
2. Exact match against `model_profiles.name`
3. Fuzzy/prefix match if no exact hit
4. Fall back to `default_context_window` setting (default: 32K)

### Caching

ETS cache with short TTL to avoid DB hits on every LLM call. Invalidated on dashboard save.

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

Three format tiers, selected by binary search against remaining budget:
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

Preserves first `head_ratio` and last `tail_ratio` of allowed size, with marker:

```
... [truncated — original was N chars, showing first/last portions] ...
```

## 4. Conversation History Budget

### Budget: configurable ratio of context window (default 55%)

### 4a. Reasoning stripping (always applied, free win)

Before building `llm_messages` in the Loop, strip `reasoning_content` / thinking blocks from all previous assistant messages. The canonical `state.messages` keeps reasoning intact for persistence and debugging. The LLM never sees old reasoning.

Estimated savings: 20–40% per reasoning model turn.

### 4b. Token-based compaction trigger

Replace `length(messages) > 40` with `TokenEstimator.estimate_messages(messages) > history_budget`.

Short-message conversations can go hundreds of exchanges. Heavy tool-use conversations compact much sooner.

`keep_recent` becomes token-based: keep the most recent messages fitting within 30% of the history budget (instead of fixed 10 messages).

### 4c. Iterative summarization

When compacting, if a previous compaction summary exists, use an **update prompt** that merges new information into the existing summary rather than regenerating from scratch.

Structured summary format:

```
## Goal
## Progress
## Key Decisions
## Files Read/Modified
## Next Steps
```

Track `<read-files>` and `<modified-files>` from tool calls, carry forward across compactions. Prevents re-reading files already processed.

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

Before writing to `SessionStore`, cap any tool result exceeding 2x the per-result cap. Prevents unbounded session file growth and ensures reloaded sessions don't blow the budget.

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
  system_prompt: 19_200,   # 15%
  history: 70_400,          # 55%
  tool_results: 25_600,     # 20%
  response_reserve: 12_800  # 10%
}
```

Computed once at session init. Stored in `PiCore.Session` state. Passed to Loop, Compaction, PromptBudget.

### Configuration

All ratios stored in DB, editable from dashboard:

- `system_prompt_budget_ratio` (default 0.15)
- `history_budget_ratio` (default 0.55)
- `tool_result_budget_ratio` (default 0.20)
- `response_reserve_ratio` (default 0.10)
- `default_context_window` (default 32,000)

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

### Safety net

If after all budgeting the total still exceeds the context window, a final guard in `Loop` before the LLM call drops the oldest non-summary messages until it fits. Logs a warning when this triggers.

## New Modules Summary

| Module | Purpose |
|--------|---------|
| `PiCore.TokenEstimator` | chars/4 estimation for strings, messages, tools |
| `PiCore.TokenBudget` | Compute and hold per-session budget allocations |
| `PiCore.PromptBudget` | Budget-aware system prompt construction |
| `PiCore.Truncate` | Head+tail truncation helper |
| `PiCore.ModelInfo` | DB-backed model metadata with ETS cache |
| `DruzhokWeb.ModelProfileLive` | Dashboard page for model profiles CRUD |
| `DruzhokWeb.SettingsLive` | Dashboard page for budget ratio settings |

## Modified Modules

| Module | Changes |
|--------|---------|
| `PiCore.Session` | Add `budget` field, pass to Loop/Compaction |
| `PiCore.Loop` | Add `transform_messages/1`, context-aware `truncate_output/1` |
| `PiCore.Compaction` | Token-based trigger, iterative summarization, structured summaries |
| `PiCore.WorkspaceLoader.Default` | Delegate to `PromptBudget` |
| `PiCore.SessionStore` | Pre-persistence size guard |
| `PiCore.Config` | Read budget ratios from DB instead of hardcoded defaults |
