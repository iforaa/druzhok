# Token Budgeting + System Runtime Injection

**Date:** 2026-03-26
**Status:** Approved

## Problem

No visibility or control over per-instance token consumption. Bots can burn unlimited tokens with no awareness of cost. The bot also doesn't know basic runtime context (its model name, current date, sandbox capabilities) unless it reads files or calls tools.

## Design

### 1. Daily Token Limit

**Storage:** Add `daily_token_limit` integer column to `instances` table. Default 0 = unlimited. Configured per-instance via dashboard.

**Query:** Add `Druzhok.LlmRequest.tokens_today(instance_name)` — returns `{input_total, output_total}` for today. Fast aggregate query on existing indexed table.

**Soft limit behavior:**
- **< 80% used:** Normal operation. Runtime section shows tokens remaining.
- **80-100% used:** Runtime section adds "Экономь токены — отвечай кратко, минимум инструментов."
- **> 100% used:** Runtime section adds "Лимит токенов исчерпан. Отвечай только на важные вопросы. Будь максимально кратким. Избегай tool calls."
- Never hard-stop — bot always responds.

**Budget calculation:** `daily_token_limit` counts total tokens (input + output). Percentage = `(input_total + output_total) / daily_token_limit * 100`.

### 2. System Runtime Injection

**Location:** `PiCore.Session.build_system_prompt` — appended after the existing model info section.

**Content (in Russian, matching existing prompt style):**

```
## Runtime

- Модель: claude-sonnet-4-6
- Дата: 2026-03-26 12:30 UTC
- Токены сегодня: 450K из 1M (55% осталось)
- Sandbox: Docker (python3, node, bash)
```

When limit is 0 (unlimited), the tokens line shows just usage without limit:
```
- Токены сегодня: 450K (без лимита)
```

When budget > 80% used, append:
```
⚠️ Экономь токены — отвечай кратко, минимум инструментов.
```

When budget > 100% used, append:
```
🛑 Лимит токенов исчерпан. Отвечай только на важные вопросы. Будь максимально кратким. Избегай tool calls.
```

### 3. TokenBudget Module

New module `Druzhok.TokenBudget` with:

- `runtime_section(instance_name, model, sandbox_type)` — returns the formatted runtime string to inject into the system prompt. Queries `LlmRequest.tokens_today`, looks up `daily_token_limit` from the instance record, formats the section.

This is called from `PiCore.Session.build_system_prompt` which already receives instance_name via extra_tool_context.

### 4. Dashboard UI

Add `daily_token_limit` input field to the instance settings area in the dashboard (near the model selector). Numeric input, placeholder "0 = unlimited". Updates via existing `update_instance_field` pattern.

## Files to Modify

| File | Change |
|------|--------|
| `druzhok/priv/repo/migrations/` | New migration: add `daily_token_limit` integer default 0 to instances |
| `druzhok/lib/druzhok/instance.ex` | Add field to schema + changeset |
| `druzhok/lib/druzhok/llm_request.ex` | Add `tokens_today(instance_name)` query |
| `druzhok/lib/druzhok/token_budget.ex` | New module: `runtime_section/3` |
| `pi_core/lib/pi_core/session.ex` | Call `Druzhok.TokenBudget.runtime_section` in `build_system_prompt`, pass through instance_name/model/sandbox from extra_tool_context |
| `druzhok_web/lib/live/dashboard_live.ex` | Add token limit input to instance settings |
