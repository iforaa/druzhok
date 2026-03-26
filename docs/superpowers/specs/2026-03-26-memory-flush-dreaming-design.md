# Memory Flush + Character Building ("Dreaming")

**Date:** 2026-03-26
**Status:** Approved

## Problem

1. **Context loss on compaction:** When conversation history is compacted (summarized), detailed facts are lost. The bot has no chance to save important information to durable memory files before the summary replaces the originals.

2. **Static character:** SOUL.md and USER.md are written once and never updated. The bot's SOUL.md says "Развивай его по мере того как узнаёшь кто ты" but there's no mechanism to do it. The bot doesn't learn about its users or evolve its personality across sessions.

## Design

### 1. Memory Flush (before compaction)

**Trigger:** Inside `Compaction.maybe_compact`, before summarizing messages.

**Flow:**
1. Compaction detects messages exceed budget → decides to compact
2. Build flush prompt: "Скоро контекст будет сжат. Запиши важные факты в memory/ через memory_write. Ответь [NO_REPLY] если нечего сохранять."
3. Run one LLM call with current messages + flush prompt (using session's `llm_fn`)
4. Execute any `memory_write` tool calls from the response
5. Proceed with normal compaction

**Constraints:**
- Silent — no streaming to Telegram, no response to user
- Single LLM iteration only — one call, execute tool calls, done
- Uses same model/credentials as the session
- If flush fails, skip and compact anyway — never block compaction
- Flush needs access to `llm_fn` and `memory_write` tool, passed via compaction opts from Session

### 2. Daily Dreaming Session

**Trigger:** `Druzhok.Scheduler` fires `:dream` tick. Configurable `dream_hour` field on instances table (0-23, default -1 = disabled). Scheduler checks hourly if current hour in instance timezone matches `dream_hour`.

**Prompt source:** `DREAM.md` in the workspace. If missing or empty, dreaming is skipped. Same pattern as HEARTBEAT.md.

**Default `DREAM.md` template:**

```markdown
# Инструкции для сна

Ты просыпаешься между сессиями. Время для рефлексии.

Ниже — выжимка из сегодняшних разговоров:

{CONVERSATIONS}

## Задачи

1. Прочитай `USER.md`. Обнови его:
   - Добавь новую информацию о пользователях из разговоров выше
   - Если какой-то факт уже есть — не дублируй
   - Если информация противоречит старой — обнови (например, "переехал", "сменил работу")
   - НЕ удаляй факты только потому что они не упоминались сегодня — у тебя неполный контекст
   - Если USER.md стал длиннее ~50 строк — объедини похожие факты, убери очевидные повторы
   - Пиши компактно: факты, не пересказ разговоров

2. Прочитай `SOUL.md`. Обнови ТОЛЬКО раздел "## Мои наблюдения" в конце — что ты заметил о себе, своём стиле, что работает а что нет. Не трогай остальные разделы.

3. Прочитай `MEMORY.md`. Перенеси важные долгосрочные факты из разговоров. Не дублируй, объединяй похожее.

Используй read, edit, memory_search. Ответь [NO_REPLY] когда закончишь.
```

**`{CONVERSATIONS}` placeholder** is replaced by Elixir before sending the prompt:
- Read all session JSONL files in `sessions/` directory
- Filter: keep only `user` and `assistant` role messages (drop `toolResult`, `tool`)
- Truncate each message content to 500 chars
- Keep last 30 messages per session
- Format as:
```
--- Chat 12345 ---
[user] привет, как дела?
[assistant] Привет! Всё работает 🌀
```
- Total digest capped at ~4000 tokens (~16K chars)

**Session flow:**
1. Scheduler reads `DREAM.md` from workspace
2. Replaces `{CONVERSATIONS}` with pre-processed conversation digest
3. Starts a temporary session (no chat_id, no Telegram)
4. Sends the dream prompt
5. Agent loop runs with tools: read, write, edit, memory_search (max 5 iterations)
6. Session terminates, no output sent anywhere

**Constraints:**
- No Telegram output — purely internal
- Uses instance's model/credentials
- Max 5 loop iterations to prevent runaway
- Results visible in dashboard Files tab (USER.md, SOUL.md, MEMORY.md changes)

### 3. SOUL.md Template Update

Add a protected appendix section to `workspace-template/SOUL.md`:

```markdown
## Мои наблюдения

_Этот раздел обновляется автоматически. Здесь я записываю что замечаю о себе._
```

The dreaming prompt explicitly tells the bot to only update this section.

### 4. Conversation Digest Builder

New module `Druzhok.DreamDigest` that:
- Reads session JSONL files from workspace `sessions/` dir
- Filters to user + assistant messages only
- Truncates content to 500 chars per message
- Keeps last 30 messages per session
- Formats as readable text with chat ID headers
- Caps total output at ~16K chars

### 5. Dashboard UI

Add `dream_hour` dropdown to instance settings (alongside heartbeat interval):
- Options: Disabled (-1), 0:00, 1:00, ... 23:00
- Label: "Dream"

## Files to Modify

| File | Change |
|------|--------|
| `pi_core/lib/pi_core/compaction.ex` | Add memory flush step before summarization |
| `druzhok/lib/druzhok/scheduler.ex` | Add dream tick handling (hourly check) |
| `druzhok/lib/druzhok/dream_digest.ex` | New module: build conversation digest from session files |
| `druzhok/lib/druzhok/instance.ex` | Add `dream_hour` field |
| `druzhok/priv/repo/migrations/` | Add `dream_hour` to instances |
| `druzhok_web/live/dashboard_live.ex` | Add dream hour dropdown |
| `workspace-template/SOUL.md` | Add "Мои наблюдения" section |
| `workspace-template/DREAM.md` | New file: dreaming instructions template |
