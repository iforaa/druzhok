# OpenClaw Alignment Refactor — Design Specification

Simplify the agent runtime by letting pi-coding-agent handle workspace file loading and system prompt building natively, matching how OpenClaw uses the library.

## Problem

The current implementation fights pi-coding-agent:
- We manually read AGENTS.md, SOUL.md, IDENTITY.md, USER.md and pass them through a chain of functions
- We build our own system prompt in `system-prompt.ts`
- `run-dispatcher.ts` carries 4 extra fields (`agentsMd`, `soulMd`, `identityMd`, `userMd`)
- `instance.ts` reads all workspace files on startup

But pi-coding-agent's `DefaultResourceLoader` already reads these files from `cwd` automatically when `createAgentSession` is called. OpenClaw just sets `cwd: workspace` and lets the library handle it.

## Changes

### Delete: `packages/core/src/runtime/system-prompt.ts`

Pi-coding-agent builds the system prompt from workspace files. We don't need our own builder. Per-chat customization is handled via `applySystemPromptOverrideToSession` (or by appending to the session's system prompt).

### Simplify: `packages/core/src/runtime/agent-run.ts`

Before:
```ts
export async function runAgent(opts: AgentRunOpts): Promise<AgentRunResult> {
  const systemPrompt = buildSystemPrompt(opts.systemPromptCtx);
  // ... manually built system prompt
}
```

After:
```ts
export async function runAgent(opts: AgentRunOpts): Promise<AgentRunResult> {
  const { session } = await createAgentSession({
    cwd: opts.workspaceDir,    // pi-coding-agent reads AGENTS.md, SOUL.md, etc.
    model: buildModel(...),
    tools: codingTools,
  });

  // Only override system prompt if there's per-chat customization
  if (opts.chatSystemPrompt) {
    const base = session.systemPrompt;
    session.systemPrompt = `${base}\n\n## Chat-Specific Instructions\n\n${opts.chatSystemPrompt}`;
  }

  session.subscribe(eventHandler);
  await session.prompt(opts.prompt);
}
```

`AgentRunOpts` drops `systemPromptCtx` and uses `workspaceDir` + optional `chatSystemPrompt` instead.

### Simplify: `packages/core/src/runtime/run-dispatcher.ts`

Remove `agentsMd`, `soulMd`, `identityMd`, `userMd` from `RunDispatcherOpts`. The dispatcher just passes `workspaceDir` and `chatSystemPrompt` to `runAgent`.

### Simplify: `src/instance.ts`

Stop reading workspace files on startup. Just pass `workspace` path to the dispatcher. Remove all `readMemoryFile(join(workspace, "AGENTS.md"))` etc.

### Keep: `packages/core/src/onboarding/onboarding.ts`

Onboarding writes to workspace files (IDENTITY.md, USER.md). This is still needed — but the agent itself handles onboarding naturally through BOOTSTRAP.md instructions, not through hardcoded TypeScript flow. The onboarding module becomes a utility for checking state, not for driving the flow.

### Update tests

- Delete `tests/core/runtime/system-prompt.test.ts`
- Update `tests/core/runtime/run-dispatcher.test.ts` to remove workspace file fields
- `agent-run.ts` tests are integration-level (need real provider) — keep the mock-based dispatcher tests

## Files Changed

| Action | File |
|--------|------|
| Delete | `packages/core/src/runtime/system-prompt.ts` |
| Delete | `tests/core/runtime/system-prompt.test.ts` |
| Modify | `packages/core/src/runtime/agent-run.ts` |
| Modify | `packages/core/src/runtime/run-dispatcher.ts` |
| Modify | `tests/core/runtime/run-dispatcher.test.ts` |
| Modify | `packages/core/src/index.ts` (remove system-prompt export) |
| Modify | `src/instance.ts` |
