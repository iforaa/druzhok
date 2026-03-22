# Druzhok v3 Phase 2: Telegram Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect pi_core to Telegram. Single-user bot that receives messages, runs the agent, and delivers responses with streaming.

**Architecture:** The `druzhok` app (second umbrella app) wraps pi_core with a Telegram bot. Uses Telegex for Telegram Bot API. The Telegram process receives messages, calls `PiCore.Session.prompt/2`, and delivers `{:pi_response, ...}` messages to Telegram.

**Tech Stack:** Elixir, Telegex (Telegram library), pi_core

**Spec:** `docs/superpowers/specs/2026-03-22-druzhok-v3-elixir-design.md`

---

## File Structure

```
v3/apps/
├── pi_core/           # already built
└── druzhok/
    ├── mix.exs
    ├── lib/
    │   ├── druzhok.ex
    │   ├── druzhok/
    │   │   ├── application.ex     # starts DynamicSupervisor
    │   │   ├── agent/
    │   │   │   ├── supervisor.ex  # per-user supervision tree
    │   │   │   └── telegram.ex    # Telegram bot GenServer
    │   │   ├── workspace_loader.ex # custom loader (extends pi_core default)
    │   │   └── instance_manager.ex # create/stop user agents
    └── test/
        ├── test_helper.exs
        └── druzhok/
            └── agent/
                └── telegram_test.exs
```

---

### Task 1: Create druzhok app

- [ ] Create app: `cd v3/apps && mix new druzhok --sup`
- [ ] Add deps to mix.exs: `{:pi_core, in_umbrella: true}`, `{:telegex, "~> 1.8"}`
- [ ] Start DynamicSupervisor in application.ex
- [ ] Verify: `mix deps.get && mix compile`
- [ ] Commit

### Task 2: Telegram bot GenServer

- [ ] Implement `Druzhok.Agent.Telegram` — GenServer that:
  - Starts Telegex long-polling on init
  - Receives updates, extracts text
  - Calls `PiCore.Session.prompt/2`
  - Receives `{:pi_response, ...}` and sends to Telegram
  - Handles /start, /reset, /abort commands
- [ ] Write tests with mock session
- [ ] Commit

### Task 3: Per-user supervision tree

- [ ] Implement `Druzhok.Agent.Supervisor` — starts:
  - PiCore.Session (with workspace, model, api config)
  - Druzhok.Agent.Telegram (with bot token, session PID)
- [ ] Implement `Druzhok.InstanceManager` — create/stop users via DynamicSupervisor
- [ ] Commit

### Task 4: Custom workspace loader

- [ ] Implement `Druzhok.WorkspaceLoader` — extends default with:
  - USER.md only in DM (not groups)
  - MEMORY.md only in DM
- [ ] Commit

### Task 5: Integration test

- [ ] Start a real bot with NEBIUS_API_KEY and DRUZHOK_TELEGRAM_TOKEN
- [ ] Verify it responds to messages
- [ ] Commit
