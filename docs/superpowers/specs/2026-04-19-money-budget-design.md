# Money-Based Daily Budget Design

## Goal

Replace the current token-based budget with a money-based daily budget per bot. Default **$0.50/day**, reset at midnight in the bot's timezone, blocks further requests with a user-facing error when exhausted.

## Motivation

The current `instances.daily_token_limit` field is vestigial: the code only checks whether it equals `0` (unlimited) — the actual value is ignored. Even if it were enforced, tokens are a bad unit: 1,000 tokens on Claude Opus costs $0.09, the same 1,000 tokens on xiaomi/mimo-v2-pro costs $0.0006 — 150× different real spend. A token cap gives unpredictable monthly bills.

OpenRouter returns the exact cost per request (when `usage: {include: true}` is sent), and the `usage_logs.cost_cents` column already exists but is never populated. Wiring cost-tracking end-to-end and switching the budget to cents gives predictable, human-understandable limits.

## Architecture

One responsibility per component:

- **`Druzhok.Budget`** — owns check / deduct / reset logic. Operates in cents. Lazy daily reset (no cron).
- **`DruzhokWebWeb.LlmFormat`** — injects `usage: {include: true}` into outbound OpenRouter requests; extracts `usage.cost` from responses.
- **`DruzhokWebWeb.LlmProxyController`** — returns HTTP 429 + friendly error message when budget exceeded.
- **`Druzhok.ModelCatalog`** — fallback price table (per-million-token input/output cents) for models when OpenRouter omits `usage.cost`.
- **Dashboard settings tab** — budget input, today's usage display with progress bar.

## Schema Changes

### `instances` table — new column

```sql
ALTER TABLE instances ADD COLUMN daily_budget_cents INTEGER NOT NULL DEFAULT 50;
```

- New bots default to **50 cents** ($0.50/day).
- Value of `0` means unlimited (escape hatch).

### `instances` table — migrate existing rows

For every existing instance: set `daily_budget_cents = 0` (unlimited). Rationale: the old `daily_token_limit = 0` meant unlimited for all existing bots in practice; we don't want to suddenly cap a working bot at 50 cents on deploy.

### `instances.daily_token_limit`

Keep the column for now (harmless, already `0` for everyone). Drop in a follow-up migration after budget UI has shipped and no one's using it.

### `budgets` table — repurpose columns

```sql
-- Before:
balance INTEGER DEFAULT 0        -- tokens remaining
lifetime_used INTEGER DEFAULT 0  -- total tokens ever

-- After (same column names, new semantics):
balance INTEGER DEFAULT 0        -- cents spent TODAY (not remaining)
lifetime_used INTEGER DEFAULT 0  -- cents spent ALL TIME
reset_at DATE                    -- NEW: the date `balance` counts spend for
```

The `balance` flip from "remaining" → "spent today" is cleaner than adding a new column: the budget limit lives on `instances.daily_budget_cents`, and the counter on `budgets.balance`. Rename the Ecto field to `spent_today_cents` for clarity even though the SQL column stays `balance`.

## Reset Logic (lazy, no cron)

On every `Budget.check/1`:

1. Load the bot's `timezone` (default `"UTC"`).
2. Compute today in that timezone as a `Date`.
3. If `budget.reset_at != today`:
   - Set `balance = 0`
   - Set `reset_at = today`
   - Persist.
4. Then check `balance < instance.daily_budget_cents`.

No background job needed. Reset cost is one DB round-trip on the first call of the day; subsequent calls just compare.

## Cost Capture

### Outbound

In `LlmFormat.prepare_body/1`, add:

```elixir
body
|> Map.put_new("usage", %{"include" => true})
```

This is a stable OpenRouter API — when set, the streamed `usage` chunk and the sync response both include a `cost` field (USD, float, e.g. `0.00012`).

### Inbound

Two paths:

**Sync (`sync_proxy`):**
```elixir
cost_usd = get_in(decoded, ["usage", "cost"]) || 0.0
cost_cents = round(cost_usd * 100)
```

**Stream (`stream_proxy` and `fake_stream_proxy`):**
In the SSE loop, when a chunk contains `"usage"`, extract `cost` alongside the prompt/completion tokens we already capture. Pass into `meter/*`.

### Persistence

`meter/*` writes `cost_cents` into `usage_logs` (column already exists, currently always 0) and calls `Budget.deduct(instance_id, cost_cents)`.

### Fallback

Some upstreams may omit `usage.cost`. If `cost_cents == 0` but we used real tokens (prompt + completion > 0), compute via `ModelCatalog.price_per_million(model)`:

```elixir
%{input: in_price, output: out_price} = ModelCatalog.price_per_million(model)
fallback_cents = round(
  prompt_tokens / 1_000_000 * in_price +
  completion_tokens / 1_000_000 * out_price
)
```

Seed the table with the models we actually use:

```elixir
@prices %{
  "xiaomi/mimo-v2-pro" => %{input: 10, output: 50},            # 10¢ / 50¢ per M tokens (example)
  "anthropic/claude-opus-4.6" => %{input: 1500, output: 7500},
  "google/gemini-2.5-flash-lite" => %{input: 10, output: 40},
  # ... only models in ModelCatalog.available/0
}
```

Log a warning when falling back so you can spot gaps.

## Exceeded Behavior

In `LlmProxyController.chat_completions/2`:

```elixir
case Budget.check(instance.id) do
  {:error, :exceeded} ->
    msg = "Бюджет на сегодня исчерпан. Лимит $#{format_dollars(limit)}. " <>
          "Сбросится в #{format_reset_time(tz)}."
    json_error(conn, 429, msg, "budget_exceeded")

  {:ok, _} -> # proceed
end
```

Hermes already handles HTTP 429 errors from the proxy and surfaces the message to the user (verified: earlier token-budget code path used the same pattern).

Message in English (for EN bots) would be a parallel branch gated on `instance.language`. For the first cut, hardcode Russian — 100% of current bots are `ru`.

## Dashboard UI Changes

In the Settings tab for a bot:

**Replace** the current "Daily token limit: [____]" field with:

```
Daily budget ($)  [0.50]
Spent today       $0.23 / $0.50 (46%)  ▓▓▓▓▓░░░░░
```

- Input stores cents internally (multiply by 100 on save, divide for display).
- Live value from `Budget.spent_today_cents/1`.
- Progress bar:
  - <50% — green
  - 50–80% — yellow
  - >80% — red

No manual reset button in the first cut (YAGNI — daily reset is automatic, and ops can always update the DB).

## Data Flow

```
user message → hermes → druzhok proxy /v1/chat/completions
  1. Budget.check(instance_id)
     └─▶ Budget module:
         ├─ get/create budget row for this instance
         ├─ lazy reset: if reset_at != today-in-tz, balance = 0
         └─ return :exceeded if balance >= daily_budget_cents, else :ok
  2. if :exceeded → 429 with Russian message → hermes surfaces to user
  3. if :ok → forward to OpenRouter with `usage: {include: true}`
  4. capture cost from response:
     ├─ usage.cost present → round(cost * 100)
     └─ absent → compute from ModelCatalog prices (warn in log)
  5. meter: insert usage_log with cost_cents, Budget.deduct(cents)
```

## Testing

**Budget module:**
- `check/1` returns `{:ok, :unlimited}` when `daily_budget_cents == 0`
- `check/1` returns `{:error, :exceeded}` when `balance >= daily_budget_cents`
- `check/1` triggers reset when `reset_at != today-in-tz`, then returns `:ok`
- Reset respects instance `timezone` (set one bot to `Europe/Amsterdam`, verify boundary at midnight Amsterdam time, not UTC)
- `deduct/2` increments `balance` and `lifetime_used`

**Cost extraction:**
- `LlmFormat.extract_cost/1` returns cents from `usage.cost`
- Falls back to `ModelCatalog` pricing when `usage.cost` missing, and the pricing math is correct

**Integration:**
- Budget-exceeded request gets 429 with Russian message body
- Successful request deducts the right number of cents and logs cost in `usage_logs`

## Out of Scope

- Multi-language budget messages (English/etc.). Russian only for first cut.
- Per-user (as opposed to per-bot) budgets. The schema supports per-bot only.
- Cross-model budget migration (e.g. auto-downgrade to cheap model on exhaustion). Feature C from the decision options was rejected.
- Monthly / weekly windows. Daily only.
- Budget alerts (email / telegram notification when approaching limit). Just the progress bar for now.
- Manual reset button in dashboard.
- Removing the `daily_token_limit` column — kept for one release; drop later.

## Migration / Rollout

1. Add column `daily_budget_cents` with default `50`.
2. Backfill: `UPDATE instances SET daily_budget_cents = 0 WHERE id > 0;` — existing bots stay unlimited.
3. Deploy druzhok. New code reads the new column, enforces cents. Existing bots unaffected because they're at `0` (unlimited).
4. User opts a bot in by setting a non-zero budget via the dashboard.

Rollback: set `daily_budget_cents = 0` for all bots, redeploy old code. No data loss (old token logic is gone, but the `balance` counter value is harmless).
