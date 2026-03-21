import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createMemoryWatcher } from "@druzhok/core/memory/watcher.js";

describe("createMemoryWatcher", () => {
  let workspace: string;
  beforeEach(() => {
    workspace = mkdtempSync(join(tmpdir(), "druzhok-watch-"));
    mkdirSync(join(workspace, "memory"), { recursive: true });
  });
  afterEach(() => { rmSync(workspace, { recursive: true, force: true }); });

  it("calls onChange when a memory file is modified", async () => {
    const onChange = vi.fn();
    const watcher = createMemoryWatcher(workspace, { onChange, debounceMs: 50 });
    writeFileSync(join(workspace, "MEMORY.md"), "initial");
    watcher.start();
    // Wait for watchFile poll to register, then modify
    await new Promise((r) => setTimeout(r, 150));
    writeFileSync(join(workspace, "MEMORY.md"), "new fact");
    await new Promise((r) => setTimeout(r, 300));
    expect(onChange).toHaveBeenCalled();
    watcher.stop();
  });

  it("debounces rapid changes", async () => {
    const onChange = vi.fn();
    const watcher = createMemoryWatcher(workspace, { onChange, debounceMs: 100 });
    watcher.start();
    writeFileSync(join(workspace, "MEMORY.md"), "fact 1");
    writeFileSync(join(workspace, "MEMORY.md"), "fact 2");
    writeFileSync(join(workspace, "MEMORY.md"), "fact 3");
    await new Promise((r) => setTimeout(r, 300));
    expect(onChange.mock.calls.length).toBeLessThanOrEqual(2);
    watcher.stop();
  });

  it("stop prevents further callbacks", async () => {
    const onChange = vi.fn();
    const watcher = createMemoryWatcher(workspace, { onChange, debounceMs: 50 });
    watcher.start();
    watcher.stop();
    writeFileSync(join(workspace, "MEMORY.md"), "after stop");
    await new Promise((r) => setTimeout(r, 200));
    expect(onChange).not.toHaveBeenCalled();
  });
});
