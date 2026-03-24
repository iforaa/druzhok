# Group Chat Prompt Injection

## Context

AGENTS.md has static group chat instructions that contradict buffer mode behavior. OpenClaw solves this by auto-injecting mode-aware instructions per group. We also lack per-group custom prompts.

## 1. Auto Group Intro

Inject a mode-aware instruction block when building group prompts, replacing the static AGENTS.md section.

**Buffer mode** (prepended to triggered message):
```
[Системная инструкция: Ты в групповом чате. Тебя вызвали по имени или ответом на твоё сообщение. Контекст недавних сообщений прикреплён выше. Всегда отвечай — раз ты это видишь, значит к тебе обратились. Будь краток.]
```

**Always mode** (prepended to every message):
```
[Системная инструкция: Ты в групповом чате и видишь все сообщения. Если к тебе не обращаются и ты не можешь добавить ценности — ответь [NO_REPLY]. Не доминируй в разговоре.]
```

**Where**: `process_group_message_buffer` and `process_group_message_always` in `telegram.ex`.

**AGENTS.md**: Remove the "Групповые чаты" section — now auto-injected.

## 2. Per-Group System Prompt

**Migration**: Add `system_prompt` (text, default nil) to `allowed_chats`.

**Injection order**:
```
[Системная инструкция: mode-aware intro]
[Инструкция для этого чата: per-group prompt]
[Сообщения в чате... (buffer context)]
[Текущее сообщение...]
```

**Dashboard**: Textarea in SecurityTab per approved group.

**Bot command**: `/prompt <text>` (owner-only) sets per-group prompt. `/prompt` shows current.

## Modified Files

- `v3/apps/druzhok/lib/druzhok/agent/telegram.ex` — inject group intro + per-group prompt
- `v3/apps/druzhok/lib/druzhok/agent/router.ex` — add `/prompt` command
- `v3/apps/druzhok/lib/druzhok/allowed_chat.ex` — add system_prompt field
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/components/security_tab.ex` — add textarea
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — handle save event
- Migration: add system_prompt to allowed_chats
- Workspace AGENTS.md on remote: remove static group section
