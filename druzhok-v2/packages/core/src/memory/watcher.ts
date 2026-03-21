import { watch, type FSWatcher } from "node:fs";
import { join } from "node:path";
import { existsSync } from "node:fs";

export type MemoryWatcherOpts = { onChange: () => void; debounceMs?: number };
export type MemoryWatcher = { start(): void; stop(): void };

export function createMemoryWatcher(workspace: string, opts: MemoryWatcherOpts): MemoryWatcher {
  const debounceMs = opts.debounceMs ?? 1500;
  const watchers: FSWatcher[] = [];
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;

  const triggerChange = () => {
    if (stopped) return;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => { if (!stopped) opts.onChange(); }, debounceMs);
  };

  return {
    start() {
      const memoryMd = join(workspace, "MEMORY.md");
      if (existsSync(memoryMd)) { try { watchers.push(watch(memoryMd, triggerChange)); } catch {} }
      const memoryDir = join(workspace, "memory");
      if (existsSync(memoryDir)) { try { watchers.push(watch(memoryDir, { recursive: true }, triggerChange)); } catch {} }
    },
    stop() {
      stopped = true;
      if (debounceTimer) clearTimeout(debounceTimer);
      for (const w of watchers) { try { w.close(); } catch {} }
      watchers.length = 0;
    },
  };
}
