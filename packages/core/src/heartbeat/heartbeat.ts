import { isHeartbeatMdEmpty } from "../memory/flush.js";

export type HeartbeatOpts = { intervalMs: number; readHeartbeatMd: () => string | null; onTick: () => Promise<void> };
export type HeartbeatManager = { start(): void; stop(): void };

export function createHeartbeatManager(opts: HeartbeatOpts): HeartbeatManager {
  let timer: ReturnType<typeof setInterval> | null = null;
  let running = false;

  const tick = async () => {
    if (running) return;
    const content = opts.readHeartbeatMd();
    if (content !== null && isHeartbeatMdEmpty(content)) return;
    running = true;
    try { await opts.onTick(); } finally { running = false; }
  };

  return {
    start() { if (timer) return; timer = setInterval(() => { void tick(); }, opts.intervalMs); },
    stop() { if (timer) { clearInterval(timer); timer = null; } },
  };
}
