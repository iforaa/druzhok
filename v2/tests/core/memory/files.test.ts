import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { readMemoryFile, appendDailyLog, listMemoryFiles, todayLogPath, yesterdayLogPath } from "@druzhok/core/memory/files.js";

describe("memory files", () => {
  let workspace: string;
  beforeEach(() => { workspace = mkdtempSync(join(tmpdir(), "druzhok-mem-")); });
  afterEach(() => { rmSync(workspace, { recursive: true, force: true }); });

  it("readMemoryFile returns null for missing file", () => { expect(readMemoryFile(join(workspace, "MEMORY.md"))).toBeNull(); });
  it("readMemoryFile reads existing file", () => {
    writeFileSync(join(workspace, "MEMORY.md"), "# Memory\nFact 1");
    expect(readMemoryFile(join(workspace, "MEMORY.md"))).toBe("# Memory\nFact 1");
  });
  it("appendDailyLog creates file and appends", () => {
    const logPath = join(workspace, "memory", "2026-03-21.md");
    appendDailyLog(workspace, "2026-03-21", "First entry");
    expect(readFileSync(logPath, "utf-8")).toContain("First entry");
    appendDailyLog(workspace, "2026-03-21", "Second entry");
    const content = readFileSync(logPath, "utf-8");
    expect(content).toContain("First entry");
    expect(content).toContain("Second entry");
  });
  it("listMemoryFiles finds MEMORY.md and daily logs", () => {
    writeFileSync(join(workspace, "MEMORY.md"), "facts");
    mkdirSync(join(workspace, "memory"), { recursive: true });
    writeFileSync(join(workspace, "memory", "2026-03-21.md"), "log");
    const files = listMemoryFiles(workspace);
    expect(files).toContain(join(workspace, "MEMORY.md"));
    expect(files).toContain(join(workspace, "memory", "2026-03-21.md"));
  });
  it("todayLogPath returns correct format", () => { expect(todayLogPath(workspace)).toMatch(/memory\/\d{4}-\d{2}-\d{2}\.md$/); });
  it("yesterdayLogPath differs from today", () => { expect(yesterdayLogPath(workspace)).not.toBe(todayLogPath(workspace)); });
});
