import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

export function readMemoryFile(path: string): string | null {
  try { return readFileSync(path, "utf-8"); } catch { return null; }
}

export function appendDailyLog(workspace: string, date: string, entry: string): void {
  const dir = join(workspace, "memory");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `${date}.md`);
  const existing = readMemoryFile(path) ?? "";
  const separator = existing && !existing.endsWith("\n") ? "\n" : "";
  writeFileSync(path, existing + (existing ? `${separator}\n${entry}\n` : `${entry}\n`));
}

export function listMemoryFiles(workspace: string): string[] {
  const files: string[] = [];
  const memoryMd = join(workspace, "MEMORY.md");
  if (existsSync(memoryMd)) files.push(memoryMd);
  const memoryDir = join(workspace, "memory");
  if (existsSync(memoryDir)) {
    for (const file of readdirSync(memoryDir)) {
      if (file.endsWith(".md")) files.push(join(memoryDir, file));
    }
  }
  return files;
}

function formatDate(date: Date): string { return date.toISOString().slice(0, 10); }
export function todayLogPath(workspace: string): string { return join(workspace, "memory", `${formatDate(new Date())}.md`); }
export function yesterdayLogPath(workspace: string): string {
  const y = new Date(); y.setDate(y.getDate() - 1);
  return join(workspace, "memory", `${formatDate(y)}.md`);
}
