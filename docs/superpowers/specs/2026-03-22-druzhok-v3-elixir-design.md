# Druzhok v3 — Elixir Rewrite Design Specification

Complete rewrite of Druzhok from TypeScript to Elixir. Replaces pi-agent-core with a custom agent loop library (pi_core), Docker containers with Firecracker microVMs, and the Go orchestrator with BEAM supervision trees.

## Context

Druzhok v2 is a TypeScript monorepo with 4 packages (shared, core, telegram, proxy), a Go orchestrator, and Docker containers per user. It works but has architectural limitations:

- 1 Docker container per user (~1GB RAM each) doesn't scale past ~100 users on one machine
- 3 separate processes (proxy, orchestrator, containers) to manage
- pi-agent-core dependency (~1900 lines) can be replaced with ~800 lines of Elixir
- No built-in distribution — multi-machine requires Kubernetes or custom coordination
- Dashboard needs separate frontend (Go serves static HTML)

Elixir/BEAM solves these: ~2KB per user process, built-in distribution, LiveView for real-time dashboard, supervision trees for fault tolerance.

## Architecture Overview

Single Elixir umbrella application with three apps:

```
v3/
├── apps/
│   ├── pi_core/         # standalone agent loop library
│   ├── druzhok/         # business logic (Telegram, users, VMs)
│   └── druzhok_web/     # Phoenix LiveView dashboard
```

### User Process Tree

Each user gets a supervision tree:

```
Agent.Supervisor (per user)
├── Agent.Telegram     ← Telegram bot, receives messages
├── Agent.Session      ← pi_core GenServer, runs agent loop
├── Agent.Heartbeat    ← periodic timer (Process.send_after)
└── Agent.Reminders    ← one-shot timers
```

Telegram process calls `PiCore.Session.prompt(pid, text)`. Session handles parallelism internally. Responses come back as messages to the Telegram process.

## pi_core — Agent Loop Library

### Public API

```elixir
# Start a session
{:ok, pid} = PiCore.Session.start_link(%{
  workspace: "/data/users/alice/workspace",
  model: "zai-org/GLM-5",
  api_url: "https://api.tokenfactory.us-central1.nebius.com/v1",
  api_key: "...",
  tools: PiCore.Tools.defaults() ++ custom_tools,
  workspace_loader: Druzhok.WorkspaceLoader,
  on_delta: fn delta -> ... end,
})

# Send prompt — returns immediately
# Response arrives as {:pi_response, %{text: "...", prompt_id: "..."}}
PiCore.Session.prompt(pid, "Create a PDF")

# Send another while first is running — pi_core handles parallelism
PiCore.Session.prompt(pid, "What's the weather?")

# Abort current work
PiCore.Session.abort(pid)

# Reset (clear history)
PiCore.Session.reset(pid)
```

### Response delivery

- **Streaming deltas:** via callback function (`on_delta`). Called during LLM streaming for real-time display.
- **Final responses:** via message passing (`{:pi_response, %{...}}`). Sent to the caller PID when a prompt completes.

### Internal Architecture

```
PiCore.Session (GenServer)
├── State: messages, system_prompt, tools, model_config,
│          active_run, parallel_runs, caller, on_delta
│
├── Prompt handling:
│   ├── prompt + idle → run inline (Task.async)
│   ├── prompt + busy → spawn parallel (history snapshot)
│   ├── run completes → send {:pi_response, ...} to caller
│   ├── parallel completes → send response + merge Q&A into history
│   └── abort → Task.shutdown on active_run
│
├── Agent loop (pure function, stateless):
│   ├── PiCore.Loop.run(messages, system_prompt, model, tools)
│   ├── calls LLM → if tool_calls: execute tools → loop
│   ├──              if text only: return
│   └── emits deltas via callback during streaming
│
├── LLM client:
│   ├── PiCore.LLM.Client — Finch HTTP + SSE streaming
│   ├── parses text_delta, tool_calls, reasoning_content
│   └── returns %{content: string, tool_calls: list}
│
├── Session persistence:
│   ├── JSONL format, append-only
│   └── save/load from workspace directory
│
└── Workspace loader (pluggable):
    ├── PiCore.WorkspaceLoader behaviour
    ├── Default: reads all .md files into system prompt
    └── Custom: consumer provides own loader module
```

The agent loop is a **pure function** — no GenServer, no side effects except tool execution. The GenServer manages state and concurrency around it. This makes the loop easy to test.

### Parallel prompt handling

Pi_core manages parallelism internally. The consumer just calls `prompt()`:

1. If session is idle → run inline
2. If session is busy → spawn a child task with a read-only snapshot of conversation history
3. Child completes → response sent to caller, Q&A merged back into main history
4. Main completes → response sent to caller

The consumer never creates sessions or manages parallelism.

### Tool System

Tools are structs with an execute function:

```elixir
%PiCore.Tool{
  name: "bash",
  description: "Run a bash command",
  parameters: %{command: %{type: :string}},
  execute: fn args, context -> ... end
}
```

**Built-in tools** (ship with pi_core): bash, read, write, edit

**Custom tools** (added by consumer): send_file, set_reminder, sandboxed_bash (Firecracker). Pi_core doesn't know about Telegram, Firecracker, or any druzhok-specific concerns. The consumer wraps tool execution with its own logic.

### Workspace Loader

Pluggable module that reads workspace files and builds the system prompt.

```elixir
defmodule PiCore.WorkspaceLoader do
  @callback load(workspace_path :: String.t(), opts :: map()) :: String.t()
end
```

Pi_core ships a default loader that reads all .md files. Druzhok provides its own loader with custom rules (USER.md only in DM, BOOTSTRAP.md deleted after onboarding, etc.).

## Druzhok App — Business Logic

### Instance Manager

Creates/stops user agent trees via DynamicSupervisor.

```elixir
Druzhok.InstanceManager.create("alice", telegram_token, model)
# → starts Agent.Supervisor with Telegram, Session, Heartbeat, Reminders
# → creates workspace from template
# → saves to database

Druzhok.InstanceManager.stop("alice")
# → terminates supervision tree
# → VM frozen (if Firecracker)
```

### LLM Proxy

Plug middleware that validates user proxy keys and injects the real Nebius API key before forwarding. Built into the Phoenix endpoint — no separate process.

### Heartbeat

`Process.send_after` timer. HEARTBEAT.md content is the activation switch — empty file means skip (no API call). Always runs, no `enabled` flag.

### Firecracker Integration (Phase 4)

Each user gets a persistent microVM. Bash/Python/Node runs inside the VM via vsock. The druzhok app provides a `sandboxed_bash` tool that replaces pi_core's default bash tool, routing execution through the VM.

## Druzhok Web — Phoenix Dashboard

Phoenix LiveView. Real-time updates via WebSocket — no polling, no separate frontend.

- List instances with live status
- Create/stop instances
- Workspace file browser
- Live log streaming
- Heartbeat configuration

## File Structure

```
v3/
├── mix.exs
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   └── runtime.exs
├── apps/
│   ├── pi_core/
│   │   ├── mix.exs                  # deps: finch, jason
│   │   ├── lib/
│   │   │   ├── pi_core.ex
│   │   │   ├── session.ex
│   │   │   ├── loop.ex
│   │   │   ├── llm/
│   │   │   │   ├── client.ex
│   │   │   │   └── sse_parser.ex
│   │   │   ├── tools/
│   │   │   │   ├── tool.ex
│   │   │   │   ├── bash.ex
│   │   │   │   ├── read.ex
│   │   │   │   ├── write.ex
│   │   │   │   └── edit.ex
│   │   │   ├── workspace_loader.ex
│   │   │   └── session_store.ex
│   │   └── test/
│   ├── druzhok/
│   │   ├── mix.exs                  # deps: pi_core, ecto, postgrex, telegex
│   │   ├── lib/
│   │   │   ├── druzhok.ex
│   │   │   ├── agent/
│   │   │   │   ├── supervisor.ex
│   │   │   │   ├── telegram.ex
│   │   │   │   ├── heartbeat.ex
│   │   │   │   └── reminders.ex
│   │   │   ├── tools/
│   │   │   │   ├── send_file.ex
│   │   │   │   ├── sandboxed_bash.ex
│   │   │   │   └── reminder.ex
│   │   │   ├── workspace_loader.ex
│   │   │   ├── instance_manager.ex
│   │   │   ├── llm_proxy.ex
│   │   │   ├── vm/
│   │   │   │   ├── manager.ex
│   │   │   │   ├── connection.ex
│   │   │   │   └── tunnel.ex
│   │   │   └── repo.ex
│   │   └── test/
│   └── druzhok_web/
│       ├── mix.exs                  # deps: phoenix, phoenix_live_view
│       ├── lib/
│       │   ├── druzhok_web.ex
│       │   ├── router.ex
│       │   ├── endpoint.ex
│       │   └── live/
│       │       ├── dashboard_live.ex
│       │       ├── workspace_live.ex
│       │       └── logs_live.ex
│       └── test/
└── workspace-template/
    ├── AGENTS.md
    ├── SOUL.md
    ├── IDENTITY.md
    ├── USER.md
    ├── BOOTSTRAP.md
    └── HEARTBEAT.md
```

## Dependencies

```
pi_core:      finch, jason
druzhok:      pi_core, ecto, postgrex, telegex
druzhok_web:  druzhok, phoenix, phoenix_live_view
```

## Phased Implementation

### Phase 0: Repo reorg [1 day]
Move v2 to `v2/`, create `v3/` umbrella.

### Phase 1: pi_core [1-2 weeks]
SSE client, tool schema, agent loop, built-in tools, session persistence, workspace loader. Test against real Nebius API.

### Phase 2: Telegram [1 week]
Telegram client, wire to pi_core, streaming delivery, commands, custom tools (send_file, reminder).

### Phase 3: Multi-tenancy + dashboard [1-2 weeks]
DynamicSupervisor, Ecto + Postgres, LLM proxy plug, LiveView dashboard, heartbeat.

### Phase 4: Firecracker [2-3 weeks]
VM lifecycle, vsock communication, persistent VMs, snapshot/restore, reverse proxy.

### Phase 5: Production [1 week]
Mix release, systemd + Caddy, monitoring (Telemetry + Prometheus).

## Key Design Decisions

1. **Umbrella app** — pi_core is a standalone library, could be published as a hex package
2. **GenServer per session** — crash isolation, natural concurrency, supervision
3. **Agent loop is a pure function** — GenServer manages state around it
4. **Parallelism inside pi_core** — consumer just calls prompt(), pi_core handles busy/idle
5. **Responses via callback (streaming) + messages (final)** — flexible for any consumer
6. **Pluggable workspace loader** — pi_core has no opinion on file conventions
7. **Tools are just structs** — pi_core doesn't know about Telegram or Firecracker
8. **HEARTBEAT.md is the activation switch** — no enabled flag, empty file = skip
9. **No Docker** — Firecracker microVMs for isolation (Phase 4)
10. **No separate proxy/orchestrator** — everything in one Elixir app
