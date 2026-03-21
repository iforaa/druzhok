# Druzhok v2 Phase 5: Heartbeat + Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the heartbeat mechanism (periodic proactive agent turns) and the skills system (markdown instruction files with regex triggers).

**Architecture:** Both modules live in `@druzhok/core`. Heartbeat uses the flush logic from Phase 3 (`isHeartbeatMdEmpty`) and the reply pipeline from Phase 4. Skills are loaded from `workspace/skills/<name>/SKILL.md` with YAML frontmatter.

**Tech Stack:** `@druzhok/shared`, `js-yaml`, `vitest`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md` — sections "Heartbeat Mechanism", "Skills System"

---

## File Structure

```
packages/core/src/
├── heartbeat/
│   ├── heartbeat.ts              # Timer, HEARTBEAT.md loading, run logic
│   └── parse-interval.ts         # Parse "30m", "1h", "2h30m" strings
├── skills/
│   ├── loader.ts                 # Parse SKILL.md YAML frontmatter
│   └── registry.ts               # Discover skills, match triggers
tests/core/
├── heartbeat/
│   ├── heartbeat.test.ts
│   └── parse-interval.test.ts
├── skills/
│   ├── loader.test.ts
│   └── registry.test.ts
```

---

### Task 1: Interval Parser

**Files:**
- Create: `packages/core/src/heartbeat/parse-interval.ts`
- Create: `tests/core/heartbeat/parse-interval.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/heartbeat/parse-interval.test.ts
import { describe, it, expect } from "vitest";
import { parseInterval } from "@druzhok/core/heartbeat/parse-interval.js";

describe("parseInterval", () => {
  it("parses minutes", () => { expect(parseInterval("30m")).toBe(30 * 60 * 1000); });
  it("parses hours", () => { expect(parseInterval("1h")).toBe(60 * 60 * 1000); });
  it("parses seconds", () => { expect(parseInterval("45s")).toBe(45 * 1000); });
  it("parses combined h+m", () => { expect(parseInterval("1h30m")).toBe(90 * 60 * 1000); });
  it("returns null for invalid", () => { expect(parseInterval("foo")).toBeNull(); });
  it("returns null for empty", () => { expect(parseInterval("")).toBeNull(); });
});
```

- [ ] **Step 2: Implement parse-interval.ts**

```ts
// packages/core/src/heartbeat/parse-interval.ts

export function parseInterval(input: string): number | null {
  if (!input) return null;
  const regex = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/;
  const match = input.trim().match(regex);
  if (!match || (!match[1] && !match[2] && !match[3])) return null;
  const hours = parseInt(match[1] ?? "0", 10);
  const minutes = parseInt(match[2] ?? "0", 10);
  const seconds = parseInt(match[3] ?? "0", 10);
  return (hours * 3600 + minutes * 60 + seconds) * 1000;
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add interval parser for heartbeat timer"
```

---

### Task 2: Heartbeat Manager

**Files:**
- Create: `packages/core/src/heartbeat/heartbeat.ts`
- Create: `tests/core/heartbeat/heartbeat.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/heartbeat/heartbeat.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createHeartbeatManager } from "@druzhok/core/heartbeat/heartbeat.js";

describe("createHeartbeatManager", () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it("calls onTick at configured interval", async () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const manager = createHeartbeatManager({
      intervalMs: 1000,
      readHeartbeatMd: () => "- Check builds",
      onTick,
    });
    manager.start();
    vi.advanceTimersByTime(1000);
    expect(onTick).toHaveBeenCalledTimes(1);
    manager.stop();
  });

  it("skips tick when HEARTBEAT.md is empty", async () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const manager = createHeartbeatManager({
      intervalMs: 1000,
      readHeartbeatMd: () => "# Heartbeat\n",
      onTick,
    });
    manager.start();
    vi.advanceTimersByTime(1000);
    expect(onTick).not.toHaveBeenCalled();
    manager.stop();
  });

  it("skips tick when HEARTBEAT.md is missing", async () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const manager = createHeartbeatManager({
      intervalMs: 1000,
      readHeartbeatMd: () => null,
      onTick,
    });
    manager.start();
    vi.advanceTimersByTime(1000);
    // null = file missing = let model decide, so tick runs
    expect(onTick).toHaveBeenCalledTimes(1);
    manager.stop();
  });

  it("skips tick when previous is still running", async () => {
    let resolveFirst: () => void;
    const firstCall = new Promise<void>((r) => { resolveFirst = r; });
    const onTick = vi.fn().mockReturnValueOnce(firstCall).mockResolvedValue(undefined);
    const manager = createHeartbeatManager({
      intervalMs: 1000,
      readHeartbeatMd: () => "- task",
      onTick,
    });
    manager.start();
    vi.advanceTimersByTime(1000); // first tick starts
    vi.advanceTimersByTime(1000); // second tick skipped (first still running)
    expect(onTick).toHaveBeenCalledTimes(1);
    resolveFirst!();
    manager.stop();
  });

  it("stop clears the timer", () => {
    const onTick = vi.fn().mockResolvedValue(undefined);
    const manager = createHeartbeatManager({
      intervalMs: 1000,
      readHeartbeatMd: () => "- task",
      onTick,
    });
    manager.start();
    manager.stop();
    vi.advanceTimersByTime(5000);
    expect(onTick).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Implement heartbeat.ts**

```ts
// packages/core/src/heartbeat/heartbeat.ts
import { isHeartbeatMdEmpty } from "../memory/flush.js";

export type HeartbeatOpts = {
  intervalMs: number;
  readHeartbeatMd: () => string | null;
  onTick: () => Promise<void>;
};

export type HeartbeatManager = {
  start(): void;
  stop(): void;
};

export function createHeartbeatManager(opts: HeartbeatOpts): HeartbeatManager {
  let timer: ReturnType<typeof setInterval> | null = null;
  let running = false;

  const tick = async () => {
    if (running) return;
    const content = opts.readHeartbeatMd();
    // Empty content = skip (save API call). Null = file missing, let model decide.
    if (content !== null && isHeartbeatMdEmpty(content)) return;
    running = true;
    try {
      await opts.onTick();
    } finally {
      running = false;
    }
  };

  return {
    start() {
      if (timer) return;
      timer = setInterval(() => { void tick(); }, opts.intervalMs);
    },
    stop() {
      if (timer) { clearInterval(timer); timer = null; }
    },
  };
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add heartbeat manager with empty-file skip"
```

---

### Task 3: Skill Loader

**Files:**
- Create: `packages/core/src/skills/loader.ts`
- Create: `tests/core/skills/loader.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/skills/loader.test.ts
import { describe, it, expect } from "vitest";
import { parseSkillFile, type Skill } from "@druzhok/core/skills/loader.js";

describe("parseSkillFile", () => {
  it("parses SKILL.md with YAML frontmatter", () => {
    const content = `---
name: setup
description: First-time setup guide
triggers:
  - "^/setup$"
  - "help me set up"
---

# Setup Instructions

Step 1: Install...`;

    const skill = parseSkillFile(content);
    expect(skill).not.toBeNull();
    expect(skill!.name).toBe("setup");
    expect(skill!.description).toBe("First-time setup guide");
    expect(skill!.triggers).toEqual(["^/setup$", "help me set up"]);
    expect(skill!.body).toContain("# Setup Instructions");
    expect(skill!.body).toContain("Step 1: Install...");
  });

  it("returns null for file without frontmatter", () => {
    expect(parseSkillFile("# Just markdown")).toBeNull();
  });

  it("returns null for empty file", () => {
    expect(parseSkillFile("")).toBeNull();
  });

  it("handles frontmatter without triggers", () => {
    const content = `---
name: info
description: Info skill
---

Body text`;

    const skill = parseSkillFile(content);
    expect(skill).not.toBeNull();
    expect(skill!.triggers).toEqual([]);
  });
});
```

- [ ] **Step 2: Implement loader.ts**

Note: Use a simple frontmatter parser instead of adding js-yaml as a dependency. The frontmatter is simple enough to parse with regex.

```ts
// packages/core/src/skills/loader.ts

export type Skill = {
  name: string;
  description: string;
  triggers: string[];
  body: string;
};

export function parseSkillFile(content: string): Skill | null {
  if (!content) return null;

  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return null;

  const frontmatter = match[1];
  const body = match[2].trim();

  const name = extractField(frontmatter, "name");
  const description = extractField(frontmatter, "description");

  if (!name) return null;

  const triggers = extractList(frontmatter, "triggers");

  return { name, description: description ?? "", triggers, body };
}

function extractField(yaml: string, field: string): string | null {
  const regex = new RegExp(`^${field}:\\s*(.+)$`, "m");
  const match = yaml.match(regex);
  if (!match) return null;
  return match[1].trim().replace(/^["']|["']$/g, "");
}

function extractList(yaml: string, field: string): string[] {
  const lines = yaml.split("\n");
  const items: string[] = [];
  let inList = false;

  for (const line of lines) {
    if (line.match(new RegExp(`^${field}:`))) {
      inList = true;
      continue;
    }
    if (inList) {
      const itemMatch = line.match(/^\s+-\s+"?([^"]*)"?\s*$/);
      if (itemMatch) {
        items.push(itemMatch[1]);
      } else if (!line.match(/^\s/)) {
        break;
      }
    }
  }

  return items;
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add skill file parser"
```

---

### Task 4: Skill Registry

**Files:**
- Create: `packages/core/src/skills/registry.ts`
- Create: `tests/core/skills/registry.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/skills/registry.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createSkillRegistry } from "@druzhok/core/skills/registry.js";

describe("createSkillRegistry", () => {
  let skillsDir: string;

  beforeEach(() => {
    skillsDir = mkdtempSync(join(tmpdir(), "druzhok-skills-"));
    mkdirSync(join(skillsDir, "setup"));
    writeFileSync(join(skillsDir, "setup", "SKILL.md"), `---
name: setup
description: First-time setup
triggers:
  - "^/setup$"
---

# Setup Guide

Follow these steps...`);

    mkdirSync(join(skillsDir, "debug"));
    writeFileSync(join(skillsDir, "debug", "SKILL.md"), `---
name: debug
description: Debug helper
triggers:
  - "^/debug$"
  - "help me debug"
---

# Debug Guide

Check these things...`);
  });

  afterEach(() => {
    rmSync(skillsDir, { recursive: true, force: true });
  });

  it("discovers skills from directory", () => {
    const registry = createSkillRegistry(skillsDir);
    expect(registry.list()).toHaveLength(2);
  });

  it("matches trigger by regex", () => {
    const registry = createSkillRegistry(skillsDir);
    const match = registry.match("/setup");
    expect(match).not.toBeNull();
    expect(match!.name).toBe("setup");
  });

  it("matches partial trigger", () => {
    const registry = createSkillRegistry(skillsDir);
    const match = registry.match("help me debug this issue");
    expect(match).not.toBeNull();
    expect(match!.name).toBe("debug");
  });

  it("returns null for no match", () => {
    const registry = createSkillRegistry(skillsDir);
    expect(registry.match("hello world")).toBeNull();
  });

  it("returns skill metadata list", () => {
    const registry = createSkillRegistry(skillsDir);
    const list = registry.list();
    expect(list.some((s) => s.name === "setup")).toBe(true);
    expect(list.some((s) => s.name === "debug")).toBe(true);
  });

  it("handles empty skills directory", () => {
    const emptyDir = mkdtempSync(join(tmpdir(), "druzhok-empty-"));
    const registry = createSkillRegistry(emptyDir);
    expect(registry.list()).toHaveLength(0);
    expect(registry.match("/setup")).toBeNull();
    rmSync(emptyDir, { recursive: true, force: true });
  });
});
```

- [ ] **Step 2: Implement registry.ts**

```ts
// packages/core/src/skills/registry.ts
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parseSkillFile, type Skill } from "./loader.js";

type CompiledSkill = Skill & {
  compiledTriggers: RegExp[];
};

export type SkillRegistry = {
  list(): Array<{ name: string; description: string }>;
  match(text: string): Skill | null;
};

export function createSkillRegistry(skillsDir: string): SkillRegistry {
  const skills: CompiledSkill[] = [];

  if (!existsSync(skillsDir)) return { list: () => [], match: () => null };

  for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const skillPath = join(skillsDir, entry.name, "SKILL.md");
    if (!existsSync(skillPath)) continue;

    try {
      const content = readFileSync(skillPath, "utf-8");
      const skill = parseSkillFile(content);
      if (!skill) continue;

      const compiledTriggers = skill.triggers
        .map((t) => { try { return new RegExp(t, "i"); } catch { return null; } })
        .filter((r): r is RegExp => r !== null);

      skills.push({ ...skill, compiledTriggers });
    } catch {
      // Skip malformed skill files
    }
  }

  return {
    list() {
      return skills.map((s) => ({ name: s.name, description: s.description }));
    },
    match(text: string) {
      for (const skill of skills) {
        for (const trigger of skill.compiledTriggers) {
          if (trigger.test(text)) return skill;
        }
      }
      return null;
    },
  };
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add skill registry with regex trigger matching"
```

---

### Task 5: Module Exports

**Files:**
- Modify: `packages/core/src/index.ts`

- [ ] **Step 1: Add heartbeat and skills exports**

Append to `packages/core/src/index.ts`:

```ts
export * from "./heartbeat/parse-interval.js";
export * from "./heartbeat/heartbeat.js";
export * from "./skills/loader.js";
export * from "./skills/registry.js";
```

- [ ] **Step 2: Build and test**

Run: `pnpm build` then `pnpm test`
Expected: All tests pass, clean build

- [ ] **Step 3: Commit**

```bash
git commit -m "export heartbeat and skills from core"
```
