/**
 * Subagent spawner. Creates a background worker that runs in the "subagent" lane
 * with its own AgentSession.
 */
import type { ReplyPayload } from "@druzhok/shared";
import { enqueue } from "./command-queue.js";
import { runAgent, type AgentRunOpts } from "./agent-run.js";

export type SpawnWorkerOpts = {
  task: string;
  notify: boolean;
  workspaceDir: string;
  proxyUrl: string;
  proxyKey: string;
  model: string;
  onResult?: (result: ReplyPayload[]) => Promise<void>;
};

export type WorkerHandle = {
  id: string;
  task: string;
  promise: Promise<void>;
};

let workerCounter = 0;

/**
 * Spawn a background worker in the "subagent" lane.
 * Returns immediately with a handle. The worker runs asynchronously.
 */
export function spawnWorker(opts: SpawnWorkerOpts): WorkerHandle {
  const id = `worker-${++workerCounter}`;

  const promise = enqueue("subagent", async () => {
    const result = await runAgent({
      prompt: opts.task,
      workspaceDir: opts.workspaceDir,
      proxyUrl: opts.proxyUrl,
      proxyKey: opts.proxyKey,
      model: opts.model,
      sessionKey: id, // isolated session
    });

    if (opts.notify && opts.onResult && result.payloads.length > 0) {
      await opts.onResult(result.payloads);
    }
  });

  // Fire and forget — don't block the caller
  promise.catch((err) => {
    console.error(`[subagent] worker ${id} failed:`, err);
  });

  return { id, task: opts.task, promise };
}
