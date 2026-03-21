import { watch, watchFile, unwatchFile, type FSWatcher, type StatWatcher } from "node:fs";
import { join } from "node:path";
import { existsSync, statSync } from "node:fs";

export type MemoryWatcherOpts = { onChange: () => void; debounceMs?: number };
export type MemoryWatcher = { start(): void; stop(): void };

export function createMemoryWatcher(workspace: string, opts: MemoryWatcherOpts): MemoryWatcher {
  const debounceMs = opts.debounceMs ?? 1500;
  const fsWatchers: FSWatcher[] = [];
  const watchedFiles: string[] = [];
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;

  const triggerChange = () => {
    if (stopped) return;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => { if (!stopped) opts.onChange(); }, debounceMs);
  };

  return {
    start() {
      // Poll MEMORY.md (works reliably across all platforms, including temp dirs on macOS)
      const memoryMd = join(workspace, "MEMORY.md");
      watchFile(memoryMd, { interval: Math.max(100, debounceMs / 2) }, (curr, prev) => {
        if (curr.mtimeMs !== prev.mtimeMs) triggerChange();
      });
      watchedFiles.push(memoryMd);

      // Watch memory/ directory with fs.watch (good for directory-level events)
      const memoryDir = join(workspace, "memory");
      if (existsSync(memoryDir)) {
        try { fsWatchers.push(watch(memoryDir, { recursive: true }, triggerChange)); } catch {}
      }
    },
    stop() {
      stopped = true;
      if (debounceTimer) clearTimeout(debounceTimer);
      for (const f of watchedFiles) { try { unwatchFile(f); } catch {} }
      for (const w of fsWatchers) { try { w.close(); } catch {} }
      watchedFiles.length = 0;
      fsWatchers.length = 0;
    },
  };
}
