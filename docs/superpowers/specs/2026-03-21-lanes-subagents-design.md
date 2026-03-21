# Lanes + Subagent System — Design Specification

Add OpenClaw-style command lanes for parallel execution, a `spawn_worker` tool for background tasks, and `/abort` for cancelling runs.

## Command Queue with Lanes

In-process queue that serializes tasks per lane but allows different lanes to run in parallel.

### Lanes

| Lane | maxConcurrent | Purpose |
|------|--------------|---------|
| `main` | 1 | User messages — serialized so agent responses don't interleave |
| `cron` | 1 | Heartbeat ticks — run independently of user conversation |
| `subagent` | 3 | Background workers spawned by the agent |

### Behavior

- `enqueue(lane, task)` → returns a promise that resolves when the task completes
- Tasks in the same lane are serialized (FIFO)
- Tasks in different lanes run concurrently
- When a lane is busy, new tasks queue up
- `clear(lane)` cancels all queued (not active) tasks in a lane

### Implementation

Single file: `packages/core/src/runtime/command-queue.ts`

```ts
type Lane = { queue: QueueEntry[]; running: number; maxConcurrent: number };

function enqueue(laneName: string, task: () => Promise<T>): Promise<T>
function clear(laneName: string): void
function isActive(laneName: string): boolean
```

## Subagent Tool

A custom tool registered with pi-coding-agent that lets the agent spawn background workers.

### Tool Definition

```ts
{
  name: "spawn_worker",
  description: "Spawn a background worker for a long-running task. The worker runs independently and sends results to the user when done.",
  parameters: {
    task: { type: "string", description: "What the worker should do" },
    notify: { type: "boolean", description: "Send result to user when done", default: true }
  }
}
```

### Behavior

1. Agent calls `spawn_worker({ task: "analyze codebase", notify: true })`
2. Tool returns immediately: "Worker spawned. I'll notify you when it's done."
3. A new `createAgentSession` runs in the `subagent` lane with the task as prompt
4. When the subagent finishes, if `notify: true`, the result is sent to the user's Telegram chat
5. The subagent has the same tools (read, write, bash) and workspace access

### Session Isolation

- Subagent gets its own `AgentSession` (fresh, not sharing the parent's history)
- Subagent reads the same workspace files (AGENTS.md, SOUL.md, etc.)
- Subagent CAN read/write files in the workspace (shared filesystem)
- Subagent does NOT share conversation context with the parent

### Implementation

- `packages/core/src/runtime/subagent.ts` — spawn logic
- Registered as a custom tool in `createAgentSession`

## Abort Support

### `/abort` Command

- Kills the active run in the main lane
- Uses `AbortController.abort()` on the current `session.prompt()` call
- Responds immediately: "Отменено."
- Next message starts a fresh run

### Implementation

- Store an `AbortController` per active run
- `/abort` in `instance.ts` calls `controller.abort()` and clears the active run
- `agent-run.ts` passes the signal to `session.prompt()` (pi-coding-agent supports abort)

## Changes

| Action | File |
|--------|------|
| Create | `packages/core/src/runtime/command-queue.ts` |
| Create | `packages/core/src/runtime/subagent.ts` |
| Modify | `packages/core/src/runtime/agent-run.ts` — add abort support, expose AbortController |
| Modify | `packages/core/src/runtime/run-dispatcher.ts` — use command queue for main lane |
| Modify | `src/instance.ts` — add /abort, wire heartbeat to cron lane |
| Create | `tests/core/runtime/command-queue.test.ts` |
| Create | `tests/core/runtime/subagent.test.ts` |
