# Druzhok v2 Phase 3: Memory System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the OpenClaw-style memory system — plain Markdown files on disk, memory tools (`memory_search`, `memory_get`), vector search with hybrid BM25+cosine, temporal decay, and pre-compaction memory flush.

**Architecture:** Memory lives in `@druzhok/core` as a self-contained module. It manages the workspace file layout (`MEMORY.md`, `memory/YYYY-MM-DD.md`), provides search via SQLite-backed vector index, and exposes the flush mechanism. The embedding API calls go through the proxy's `/v1/embeddings` endpoint.

**Tech Stack:** `better-sqlite3` (vector index), `@druzhok/shared`, `vitest`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md` — sections "Memory System", "Memory Indexing", "Compaction"

**Depends on:** Phase 1 (shared types, core config)

---

## File Structure

```
packages/core/src/
├── memory/
│   ├── files.ts                  # Read/write MEMORY.md and daily logs
│   ├── chunker.ts                # Split markdown into ~400 token chunks with overlap
│   ├── embeddings.ts             # Call proxy /v1/embeddings endpoint
│   ├── bm25.ts                   # BM25 keyword scoring
│   ├── index-store.ts            # SQLite store for chunks + embeddings
│   ├── search.ts                 # Hybrid search: vector + BM25 + decay + MMR
│   ├── memory-manager.ts         # Orchestrator: index, search, flush
│   └── flush.ts                  # Pre-compaction memory flush logic
tests/core/
├── memory/
│   ├── files.test.ts
│   ├── chunker.test.ts
│   ├── bm25.test.ts
│   ├── search.test.ts
│   └── flush.test.ts
```

---

### Task 1: Memory File Operations

**Files:**
- Create: `packages/core/src/memory/files.ts`
- Create: `tests/core/memory/files.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/memory/files.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  readMemoryFile,
  appendDailyLog,
  listMemoryFiles,
  todayLogPath,
  yesterdayLogPath,
} from "@druzhok/core/memory/files.js";

describe("memory files", () => {
  let workspace: string;

  beforeEach(() => {
    workspace = mkdtempSync(join(tmpdir(), "druzhok-mem-"));
  });

  afterEach(() => {
    rmSync(workspace, { recursive: true, force: true });
  });

  it("readMemoryFile returns null for missing file", () => {
    expect(readMemoryFile(join(workspace, "MEMORY.md"))).toBeNull();
  });

  it("readMemoryFile reads existing file", () => {
    const path = join(workspace, "MEMORY.md");
    require("node:fs").writeFileSync(path, "# Memory\nFact 1");
    expect(readMemoryFile(path)).toBe("# Memory\nFact 1");
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
    require("node:fs").writeFileSync(join(workspace, "MEMORY.md"), "facts");
    require("node:fs").mkdirSync(join(workspace, "memory"), { recursive: true });
    require("node:fs").writeFileSync(join(workspace, "memory", "2026-03-21.md"), "log");

    const files = listMemoryFiles(workspace);
    expect(files).toContain(join(workspace, "MEMORY.md"));
    expect(files).toContain(join(workspace, "memory", "2026-03-21.md"));
  });

  it("todayLogPath returns correct format", () => {
    const path = todayLogPath(workspace);
    expect(path).toMatch(/memory\/\d{4}-\d{2}-\d{2}\.md$/);
  });

  it("yesterdayLogPath returns correct format", () => {
    const path = yesterdayLogPath(workspace);
    expect(path).toMatch(/memory\/\d{4}-\d{2}-\d{2}\.md$/);
    expect(path).not.toBe(todayLogPath(workspace));
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/files.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement files.ts**

```ts
// packages/core/src/memory/files.ts
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";

export function readMemoryFile(path: string): string | null {
  try {
    return readFileSync(path, "utf-8");
  } catch {
    return null;
  }
}

export function appendDailyLog(workspace: string, date: string, entry: string): void {
  const dir = join(workspace, "memory");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `${date}.md`);
  const existing = readMemoryFile(path) ?? "";
  const separator = existing && !existing.endsWith("\n") ? "\n" : "";
  const newEntry = existing ? `${separator}\n${entry}\n` : `${entry}\n`;
  writeFileSync(path, existing + newEntry);
}

export function listMemoryFiles(workspace: string): string[] {
  const files: string[] = [];

  const memoryMd = join(workspace, "MEMORY.md");
  if (existsSync(memoryMd)) {
    files.push(memoryMd);
  }

  const memoryDir = join(workspace, "memory");
  if (existsSync(memoryDir)) {
    for (const file of readdirSync(memoryDir)) {
      if (file.endsWith(".md")) {
        files.push(join(memoryDir, file));
      }
    }
  }

  return files;
}

function formatDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export function todayLogPath(workspace: string): string {
  return join(workspace, "memory", `${formatDate(new Date())}.md`);
}

export function yesterdayLogPath(workspace: string): string {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  return join(workspace, "memory", `${formatDate(yesterday)}.md`);
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/files.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/memory/files.ts tests/core/memory/files.test.ts
git commit -m "add memory file operations"
```

---

### Task 2: Text Chunker

**Files:**
- Create: `packages/core/src/memory/chunker.ts`
- Create: `tests/core/memory/chunker.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/memory/chunker.test.ts
import { describe, it, expect } from "vitest";
import { chunkMarkdown, type Chunk } from "@druzhok/core/memory/chunker.js";

describe("chunkMarkdown", () => {
  it("returns single chunk for short text", () => {
    const chunks = chunkMarkdown("Hello world", "test.md");
    expect(chunks).toHaveLength(1);
    expect(chunks[0].text).toBe("Hello world");
    expect(chunks[0].file).toBe("test.md");
    expect(chunks[0].startLine).toBe(1);
  });

  it("splits long text into overlapping chunks", () => {
    // ~400 tokens ≈ ~1600 chars, overlap ~80 tokens ≈ ~320 chars
    const line = "word ".repeat(100); // 500 chars per line
    const text = Array(10).fill(line).join("\n"); // ~5000 chars
    const chunks = chunkMarkdown(text, "test.md", { targetTokens: 100, overlapTokens: 20 });
    expect(chunks.length).toBeGreaterThan(1);

    // Check overlap: end of chunk N should overlap with start of chunk N+1
    for (let i = 0; i < chunks.length - 1; i++) {
      const endOfCurrent = chunks[i].text.slice(-50);
      const startOfNext = chunks[i + 1].text.slice(0, 100);
      // Some overlap should exist
      expect(startOfNext).toContain(endOfCurrent.trim().split(" ").pop());
    }
  });

  it("preserves line numbers across chunks", () => {
    const lines = Array.from({ length: 20 }, (_, i) => `Line ${i + 1}`);
    const text = lines.join("\n");
    const chunks = chunkMarkdown(text, "test.md", { targetTokens: 10, overlapTokens: 2 });
    expect(chunks[0].startLine).toBe(1);
    for (let i = 1; i < chunks.length; i++) {
      expect(chunks[i].startLine).toBeGreaterThan(chunks[i - 1].startLine);
    }
  });

  it("handles empty text", () => {
    const chunks = chunkMarkdown("", "test.md");
    expect(chunks).toHaveLength(0);
  });

  it("returns end line for each chunk", () => {
    const text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5";
    const chunks = chunkMarkdown(text, "test.md", { targetTokens: 5, overlapTokens: 1 });
    for (const chunk of chunks) {
      expect(chunk.endLine).toBeGreaterThanOrEqual(chunk.startLine);
    }
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/chunker.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement chunker.ts**

```ts
// packages/core/src/memory/chunker.ts

export type Chunk = {
  text: string;
  file: string;
  startLine: number;
  endLine: number;
};

type ChunkOpts = {
  targetTokens?: number;
  overlapTokens?: number;
};

// Rough token estimate: ~4 chars per token
function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

export function chunkMarkdown(
  text: string,
  file: string,
  opts?: ChunkOpts
): Chunk[] {
  if (!text.trim()) return [];

  const targetTokens = opts?.targetTokens ?? 400;
  const overlapTokens = opts?.overlapTokens ?? 80;
  const targetChars = targetTokens * 4;
  const overlapChars = overlapTokens * 4;

  const lines = text.split("\n");

  if (text.length <= targetChars) {
    return [{
      text: text,
      file,
      startLine: 1,
      endLine: lines.length,
    }];
  }

  const chunks: Chunk[] = [];
  let currentStart = 0; // line index

  while (currentStart < lines.length) {
    // Accumulate lines until we hit targetChars
    let charCount = 0;
    let currentEnd = currentStart;

    while (currentEnd < lines.length && charCount < targetChars) {
      charCount += lines[currentEnd].length + 1; // +1 for newline
      currentEnd++;
    }

    const chunkLines = lines.slice(currentStart, currentEnd);
    chunks.push({
      text: chunkLines.join("\n"),
      file,
      startLine: currentStart + 1,
      endLine: currentEnd,
    });

    // Move forward by (targetChars - overlapChars) worth of lines
    const advanceChars = targetChars - overlapChars;
    let advancedChars = 0;
    let nextStart = currentStart;

    while (nextStart < currentEnd && advancedChars < advanceChars) {
      advancedChars += lines[nextStart].length + 1;
      nextStart++;
    }

    if (nextStart <= currentStart) nextStart = currentStart + 1;
    if (nextStart >= lines.length) break;

    currentStart = nextStart;
  }

  return chunks;
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/chunker.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/memory/chunker.ts tests/core/memory/chunker.test.ts
git commit -m "add markdown chunker with overlap"
```

---

### Task 3: BM25 Keyword Scoring

**Files:**
- Create: `packages/core/src/memory/bm25.ts`
- Create: `tests/core/memory/bm25.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/memory/bm25.test.ts
import { describe, it, expect } from "vitest";
import { createBM25Index, type BM25Result } from "@druzhok/core/memory/bm25.js";

describe("BM25", () => {
  const docs = [
    { id: "a", text: "the quick brown fox jumps over the lazy dog" },
    { id: "b", text: "the lazy cat sleeps all day long" },
    { id: "c", text: "a quick red fox runs through the forest" },
  ];

  it("ranks matching documents by relevance", () => {
    const index = createBM25Index(docs);
    const results = index.search("quick fox");
    expect(results.length).toBeGreaterThan(0);
    // Documents with "quick" and "fox" should rank highest
    expect(results[0].id).toBe("a");
  });

  it("returns empty for no matches", () => {
    const index = createBM25Index(docs);
    const results = index.search("elephant");
    expect(results).toHaveLength(0);
  });

  it("scores are positive numbers", () => {
    const index = createBM25Index(docs);
    const results = index.search("lazy");
    for (const r of results) {
      expect(r.score).toBeGreaterThan(0);
    }
  });

  it("handles empty query", () => {
    const index = createBM25Index(docs);
    expect(index.search("")).toHaveLength(0);
  });

  it("handles empty document set", () => {
    const index = createBM25Index([]);
    expect(index.search("test")).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/bm25.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement bm25.ts**

```ts
// packages/core/src/memory/bm25.ts

export type BM25Doc = {
  id: string;
  text: string;
};

export type BM25Result = {
  id: string;
  score: number;
};

type TokenizedDoc = {
  id: string;
  tokens: string[];
  length: number;
};

function tokenize(text: string): string[] {
  return text.toLowerCase().split(/\W+/).filter(Boolean);
}

const K1 = 1.5;
const B = 0.75;

export function createBM25Index(docs: BM25Doc[]) {
  const tokenizedDocs: TokenizedDoc[] = docs.map((d) => {
    const tokens = tokenize(d.text);
    return { id: d.id, tokens, length: tokens.length };
  });

  const avgDocLength =
    tokenizedDocs.length > 0
      ? tokenizedDocs.reduce((sum, d) => sum + d.length, 0) / tokenizedDocs.length
      : 0;

  // Document frequency: how many docs contain each term
  const df = new Map<string, number>();
  for (const doc of tokenizedDocs) {
    const seen = new Set(doc.tokens);
    for (const token of seen) {
      df.set(token, (df.get(token) ?? 0) + 1);
    }
  }

  const N = tokenizedDocs.length;

  return {
    search(query: string): BM25Result[] {
      const queryTokens = tokenize(query);
      if (queryTokens.length === 0 || N === 0) return [];

      const results: BM25Result[] = [];

      for (const doc of tokenizedDocs) {
        let score = 0;

        // Term frequency map for this doc
        const tf = new Map<string, number>();
        for (const token of doc.tokens) {
          tf.set(token, (tf.get(token) ?? 0) + 1);
        }

        for (const term of queryTokens) {
          const termFreq = tf.get(term) ?? 0;
          if (termFreq === 0) continue;

          const docFreq = df.get(term) ?? 0;
          const idf = Math.log((N - docFreq + 0.5) / (docFreq + 0.5) + 1);

          const numerator = termFreq * (K1 + 1);
          const denominator = termFreq + K1 * (1 - B + B * (doc.length / avgDocLength));

          score += idf * (numerator / denominator);
        }

        if (score > 0) {
          results.push({ id: doc.id, score });
        }
      }

      return results.sort((a, b) => b.score - a.score);
    },
  };
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/bm25.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/memory/bm25.ts tests/core/memory/bm25.test.ts
git commit -m "add BM25 keyword scoring for memory search"
```

---

### Task 4: Embeddings Client

**Files:**
- Create: `packages/core/src/memory/embeddings.ts`

This is a thin HTTP client — no tests needed beyond integration. It calls the proxy's `/v1/embeddings` endpoint.

- [ ] **Step 1: Implement embeddings.ts**

```ts
// packages/core/src/memory/embeddings.ts

export type EmbeddingOpts = {
  proxyUrl: string;
  proxyKey: string;
  model?: string;
};

export async function getEmbeddings(
  texts: string[],
  opts: EmbeddingOpts
): Promise<number[][]> {
  const model = opts.model ?? "text-embedding-3-small";
  const response = await fetch(`${opts.proxyUrl.replace(/\/$/, "")}/v1/embeddings`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${opts.proxyKey}`,
    },
    body: JSON.stringify({ input: texts, model }),
  });

  if (!response.ok) {
    throw new Error(`Embedding request failed: ${response.status} ${response.statusText}`);
  }

  const data = (await response.json()) as {
    data: Array<{ embedding: number[] }>;
  };

  return data.data.map((d) => d.embedding);
}

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}
```

- [ ] **Step 2: Commit**

```bash
git add packages/core/src/memory/embeddings.ts
git commit -m "add embeddings client and cosine similarity"
```

---

### Task 5: Hybrid Search with Decay and MMR

**Files:**
- Create: `packages/core/src/memory/search.ts`
- Create: `tests/core/memory/search.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/memory/search.test.ts
import { describe, it, expect } from "vitest";
import {
  mergeSearchResults,
  applyTemporalDecay,
  applyMMR,
  type SearchResult,
} from "@druzhok/core/memory/search.js";

describe("mergeSearchResults", () => {
  it("merges vector and keyword results with weights", () => {
    const vector: SearchResult[] = [
      { id: "a", score: 0.9, text: "hello", file: "f1", startLine: 1, endLine: 1 },
      { id: "b", score: 0.7, text: "world", file: "f2", startLine: 1, endLine: 1 },
    ];
    const keyword: SearchResult[] = [
      { id: "b", score: 0.8, text: "world", file: "f2", startLine: 1, endLine: 1 },
      { id: "c", score: 0.6, text: "test", file: "f3", startLine: 1, endLine: 1 },
    ];

    const merged = mergeSearchResults(vector, keyword, { vectorWeight: 0.7, textWeight: 0.3 });
    expect(merged.length).toBe(3); // a, b, c
    // b should benefit from appearing in both
    const bResult = merged.find((r) => r.id === "b");
    expect(bResult).toBeDefined();
    expect(bResult!.score).toBeGreaterThan(0);
  });

  it("handles empty vector results", () => {
    const keyword: SearchResult[] = [
      { id: "a", score: 0.5, text: "test", file: "f1", startLine: 1, endLine: 1 },
    ];
    const merged = mergeSearchResults([], keyword, { vectorWeight: 0.7, textWeight: 0.3 });
    expect(merged.length).toBe(1);
  });
});

describe("applyTemporalDecay", () => {
  it("does not decay MEMORY.md", () => {
    const results: SearchResult[] = [
      { id: "a", score: 1.0, text: "fact", file: "/workspace/MEMORY.md", startLine: 1, endLine: 1 },
    ];
    const decayed = applyTemporalDecay(results, { halfLifeDays: 30 });
    expect(decayed[0].score).toBe(1.0);
  });

  it("decays old daily logs", () => {
    const oldDate = new Date();
    oldDate.setDate(oldDate.getDate() - 60);
    const dateStr = oldDate.toISOString().slice(0, 10);

    const results: SearchResult[] = [
      { id: "a", score: 1.0, text: "old note", file: `/workspace/memory/${dateStr}.md`, startLine: 1, endLine: 1 },
    ];
    const decayed = applyTemporalDecay(results, { halfLifeDays: 30 });
    expect(decayed[0].score).toBeLessThan(0.5); // 60 days > 1 half-life
  });

  it("does not decay today's log", () => {
    const today = new Date().toISOString().slice(0, 10);
    const results: SearchResult[] = [
      { id: "a", score: 1.0, text: "today", file: `/workspace/memory/${today}.md`, startLine: 1, endLine: 1 },
    ];
    const decayed = applyTemporalDecay(results, { halfLifeDays: 30 });
    expect(decayed[0].score).toBeGreaterThan(0.99);
  });
});

describe("applyMMR", () => {
  it("reduces redundant results", () => {
    const results: SearchResult[] = [
      { id: "a", score: 0.9, text: "the quick brown fox jumps", file: "f1", startLine: 1, endLine: 1 },
      { id: "b", score: 0.85, text: "the quick brown fox leaps", file: "f1", startLine: 2, endLine: 2 },
      { id: "c", score: 0.7, text: "completely different topic here", file: "f2", startLine: 1, endLine: 1 },
    ];
    const reranked = applyMMR(results, { lambda: 0.5, maxResults: 2 });
    expect(reranked).toHaveLength(2);
    // With lambda=0.5, c (diverse) should beat b (similar to a)
    expect(reranked[0].id).toBe("a");
    expect(reranked[1].id).toBe("c");
  });

  it("returns all results when fewer than maxResults", () => {
    const results: SearchResult[] = [
      { id: "a", score: 0.9, text: "hello", file: "f1", startLine: 1, endLine: 1 },
    ];
    const reranked = applyMMR(results, { lambda: 0.7, maxResults: 5 });
    expect(reranked).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/search.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement search.ts**

```ts
// packages/core/src/memory/search.ts

export type SearchResult = {
  id: string;
  score: number;
  text: string;
  file: string;
  startLine: number;
  endLine: number;
};

type MergeWeights = {
  vectorWeight: number;
  textWeight: number;
};

export function mergeSearchResults(
  vectorResults: SearchResult[],
  keywordResults: SearchResult[],
  weights: MergeWeights
): SearchResult[] {
  const total = weights.vectorWeight + weights.textWeight;
  const vw = weights.vectorWeight / total;
  const tw = weights.textWeight / total;

  const merged = new Map<string, SearchResult>();

  for (const r of vectorResults) {
    merged.set(r.id, { ...r, score: r.score * vw });
  }

  for (const r of keywordResults) {
    const existing = merged.get(r.id);
    if (existing) {
      existing.score += r.score * tw;
    } else {
      merged.set(r.id, { ...r, score: r.score * tw });
    }
  }

  return [...merged.values()].sort((a, b) => b.score - a.score);
}

type DecayOpts = {
  halfLifeDays: number;
};

function extractDateFromPath(file: string): Date | null {
  const match = file.match(/(\d{4}-\d{2}-\d{2})\.md$/);
  if (!match) return null;
  return new Date(match[1]);
}

function isEvergreen(file: string): boolean {
  return file.endsWith("MEMORY.md") || !extractDateFromPath(file);
}

export function applyTemporalDecay(
  results: SearchResult[],
  opts: DecayOpts
): SearchResult[] {
  const now = new Date();
  const lambda = Math.LN2 / opts.halfLifeDays;

  return results.map((r) => {
    if (isEvergreen(r.file)) return r;

    const fileDate = extractDateFromPath(r.file);
    if (!fileDate) return r;

    const ageInDays = (now.getTime() - fileDate.getTime()) / (1000 * 60 * 60 * 24);
    const decay = Math.exp(-lambda * Math.max(0, ageInDays));

    return { ...r, score: r.score * decay };
  });
}

type MMROpts = {
  lambda: number;
  maxResults: number;
};

function jaccardSimilarity(a: string, b: string): number {
  const tokensA = new Set(a.toLowerCase().split(/\W+/).filter(Boolean));
  const tokensB = new Set(b.toLowerCase().split(/\W+/).filter(Boolean));
  if (tokensA.size === 0 && tokensB.size === 0) return 1;

  let intersection = 0;
  for (const t of tokensA) {
    if (tokensB.has(t)) intersection++;
  }

  const union = tokensA.size + tokensB.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

export function applyMMR(
  results: SearchResult[],
  opts: MMROpts
): SearchResult[] {
  if (results.length <= 1) return results;

  const selected: SearchResult[] = [];
  const remaining = [...results];

  // First: pick the highest scoring result
  selected.push(remaining.shift()!);

  while (selected.length < opts.maxResults && remaining.length > 0) {
    let bestIdx = 0;
    let bestScore = -Infinity;

    for (let i = 0; i < remaining.length; i++) {
      const candidate = remaining[i];
      const relevance = candidate.score;

      // Max similarity to any already-selected result
      let maxSim = 0;
      for (const s of selected) {
        const sim = jaccardSimilarity(candidate.text, s.text);
        if (sim > maxSim) maxSim = sim;
      }

      const mmrScore = opts.lambda * relevance - (1 - opts.lambda) * maxSim;
      if (mmrScore > bestScore) {
        bestScore = mmrScore;
        bestIdx = i;
      }
    }

    selected.push(remaining.splice(bestIdx, 1)[0]);
  }

  return selected;
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/search.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/memory/search.ts tests/core/memory/search.test.ts
git commit -m "add hybrid search with temporal decay and MMR"
```

---

### Task 6: Pre-Compaction Memory Flush

**Files:**
- Create: `packages/core/src/memory/flush.ts`
- Create: `tests/core/memory/flush.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/memory/flush.test.ts
import { describe, it, expect } from "vitest";
import {
  shouldFlush,
  buildFlushPrompt,
  isHeartbeatMdEmpty,
} from "@druzhok/core/memory/flush.js";

describe("shouldFlush", () => {
  it("returns true when tokens exceed threshold", () => {
    expect(shouldFlush({
      estimatedTokens: 95000,
      contextWindow: 100000,
      reserveTokensFloor: 20000,
      softThresholdTokens: 4000,
      flushedThisCycle: false,
    })).toBe(true);
  });

  it("returns false when well under threshold", () => {
    expect(shouldFlush({
      estimatedTokens: 50000,
      contextWindow: 100000,
      reserveTokensFloor: 20000,
      softThresholdTokens: 4000,
      flushedThisCycle: false,
    })).toBe(false);
  });

  it("returns false if already flushed this cycle", () => {
    expect(shouldFlush({
      estimatedTokens: 95000,
      contextWindow: 100000,
      reserveTokensFloor: 20000,
      softThresholdTokens: 4000,
      flushedThisCycle: true,
    })).toBe(false);
  });
});

describe("buildFlushPrompt", () => {
  it("returns system and user prompts", () => {
    const prompts = buildFlushPrompt();
    expect(prompts.system).toContain("compaction");
    expect(prompts.user).toContain("MEMORY.md");
    expect(prompts.user).toContain("NO_REPLY");
  });
});

describe("isHeartbeatMdEmpty", () => {
  it("returns true for empty content", () => {
    expect(isHeartbeatMdEmpty("")).toBe(true);
  });

  it("returns true for only headers", () => {
    expect(isHeartbeatMdEmpty("# Heartbeat\n\n## Tasks\n")).toBe(true);
  });

  it("returns true for empty checkboxes", () => {
    expect(isHeartbeatMdEmpty("# Tasks\n- [ ]\n- [ ]\n")).toBe(true);
  });

  it("returns false for content with tasks", () => {
    expect(isHeartbeatMdEmpty("# Tasks\n- Check builds\n")).toBe(false);
  });

  it("returns false for null (file missing)", () => {
    expect(isHeartbeatMdEmpty(null)).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/flush.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement flush.ts**

```ts
// packages/core/src/memory/flush.ts

export type FlushCheck = {
  estimatedTokens: number;
  contextWindow: number;
  reserveTokensFloor: number;
  softThresholdTokens: number;
  flushedThisCycle: boolean;
};

export function shouldFlush(check: FlushCheck): boolean {
  if (check.flushedThisCycle) return false;

  const threshold =
    check.contextWindow - check.reserveTokensFloor - check.softThresholdTokens;

  return check.estimatedTokens >= threshold;
}

export function buildFlushPrompt(): { system: string; user: string } {
  return {
    system:
      "Session nearing compaction. Store durable memories now. This is a silent maintenance turn — the user will not see your response.",
    user:
      "Write durable facts to MEMORY.md and ephemeral context to memory/YYYY-MM-DD.md (use today's date). Reply with NO_REPLY if nothing to store.",
  };
}

export function isHeartbeatMdEmpty(content: string | null | undefined): boolean {
  // Missing file = not empty (let the model decide)
  if (content === null || content === undefined) return false;

  const lines = content.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    // Skip markdown headers
    if (/^#+(\s|$)/.test(trimmed)) continue;
    // Skip empty checkboxes
    if (/^[-*+]\s*(\[[\sXx]?\]\s*)?$/.test(trimmed)) continue;
    // Found actionable content
    return false;
  }
  return true;
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/core/memory/flush.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/core/src/memory/flush.ts tests/core/memory/flush.test.ts
git commit -m "add pre-compaction memory flush logic"
```

---

### Task 7: Memory Module Exports

**Files:**
- Modify: `packages/core/src/index.ts`

- [ ] **Step 1: Update barrel exports**

Add to `packages/core/src/index.ts`:

```ts
export * from "./memory/files.js";
export * from "./memory/chunker.js";
export * from "./memory/bm25.js";
export * from "./memory/embeddings.js";
export * from "./memory/search.js";
export * from "./memory/flush.js";
```

- [ ] **Step 2: Build and test**

Run: `cd druzhok-v2 && pnpm build && pnpm test`
Expected: All tests pass, clean build

- [ ] **Step 3: Commit**

```bash
git add packages/core/src/index.ts
git commit -m "export memory module from core"
```

---

## Phase 3 Complete Checklist

After all tasks are done, verify:

- [ ] `pnpm build` succeeds
- [ ] `pnpm test` all pass
- [ ] Memory file operations work (read, append, list)
- [ ] Chunker splits markdown with overlap
- [ ] BM25 scores documents by keyword relevance
- [ ] Hybrid search merges vector + keyword scores
- [ ] Temporal decay fades old daily logs, preserves MEMORY.md
- [ ] MMR re-ranking removes near-duplicates
- [ ] Pre-compaction flush checks threshold and builds correct prompts
- [ ] HEARTBEAT.md emptiness detection works
