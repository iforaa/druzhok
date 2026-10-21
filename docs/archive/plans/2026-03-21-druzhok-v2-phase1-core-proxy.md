# Druzhok v2 Phase 1: Core + Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up the TypeScript monorepo, shared types, proxy server with auth/rate-limiting/provider routing, and the core runtime skeleton that wraps pi-agent-core.

**Architecture:** pnpm monorepo with four packages (shared, core, telegram, proxy). This phase builds `shared` and `proxy` fully, plus the `core` skeleton (config loading, session key routing). Telegram and memory are Phase 2+.

**Tech Stack:** TypeScript, pnpm workspaces, `@mariozechner/pi-agent-core@0.61.0`, `@mariozechner/pi-coding-agent@0.58.3`, `@mariozechner/pi-ai@0.61.1`, `fastify`, `vitest`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md`

---

## File Structure

```
druzhok-v2/
├── package.json                          # monorepo root
├── pnpm-workspace.yaml
├── tsconfig.json                         # base tsconfig
├── tsconfig.build.json                   # build tsconfig (excludes tests)
├── vitest.config.ts
├── packages/
│   ├── shared/
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   └── src/
│   │       ├── index.ts                  # barrel export
│   │       ├── types.ts                  # ReplyPayload, InboundContext, DeliveryResult, etc.
│   │       └── tokens.ts                 # NO_REPLY, HEARTBEAT_OK constants + helpers
│   ├── proxy/
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   └── src/
│   │       ├── index.ts                  # entry point, start server
│   │       ├── server.ts                 # Fastify app setup, route registration
│   │       ├── config.ts                 # env var loading, registry file loading
│   │       ├── auth.ts                   # instance key validation middleware
│   │       ├── rate-limit.ts             # token bucket per instance key
│   │       ├── providers/
│   │       │   ├── router.ts             # model ID prefix → provider dispatch
│   │       │   ├── openai-compat.ts      # passthrough for OpenAI-compatible (OpenAI, Nebius)
│   │       │   └── anthropic.ts          # OpenAI→Anthropic request/response translation
│   │       └── health.ts                 # GET /health endpoint
│   └── core/
│       ├── package.json
│       ├── tsconfig.json
│       └── src/
│           ├── index.ts                  # barrel export
│           ├── config/
│           │   └── config.ts             # druzhok.json + env var loading
│           └── session/
│               └── session-key.ts        # session key building + parsing
├── tests/
│   ├── shared/
│   │   ├── types.test.ts
│   │   └── tokens.test.ts
│   ├── proxy/
│   │   ├── auth.test.ts
│   │   ├── rate-limit.test.ts
│   │   ├── router.test.ts
│   │   ├── anthropic.test.ts
│   │   └── server.integration.test.ts
│   └── core/
│       ├── config.test.ts
│       └── session-key.test.ts
```

---

### Task 1: Monorepo Scaffolding

**Files:**
- Create: `druzhok-v2/package.json`
- Create: `druzhok-v2/pnpm-workspace.yaml`
- Create: `druzhok-v2/tsconfig.json`
- Create: `druzhok-v2/tsconfig.build.json`
- Create: `druzhok-v2/vitest.config.ts`
- Create: `druzhok-v2/.gitignore`
- Create: `druzhok-v2/packages/shared/package.json`
- Create: `druzhok-v2/packages/shared/tsconfig.json`
- Create: `druzhok-v2/packages/proxy/package.json`
- Create: `druzhok-v2/packages/proxy/tsconfig.json`
- Create: `druzhok-v2/packages/core/package.json`
- Create: `druzhok-v2/packages/core/tsconfig.json`

- [ ] **Step 1: Create root package.json**

```json
{
  "name": "druzhok-v2",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -b tsconfig.build.json",
    "dev": "tsc -b tsconfig.build.json --watch",
    "test": "vitest run",
    "test:watch": "vitest",
    "proxy": "node packages/proxy/dist/index.js",
    "clean": "rm -rf packages/*/dist"
  },
  "devDependencies": {
    "typescript": "^5.8.0",
    "vitest": "^3.1.0",
    "@types/node": "^22.0.0",
    "@types/better-sqlite3": "^7.6.0"
  }
}
```

- [ ] **Step 2: Create pnpm-workspace.yaml**

```yaml
packages:
  - "packages/*"
```

- [ ] **Step 3: Create base tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "lib": ["ES2022"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "dist",
    "rootDir": "src"
  }
}
```

- [ ] **Step 4: Create tsconfig.build.json**

```json
{
  "files": [],
  "references": [
    { "path": "packages/shared" },
    { "path": "packages/core" },
    { "path": "packages/proxy" }
  ]
}
```

- [ ] **Step 5: Create vitest.config.ts**

```ts
import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
  },
  resolve: {
    alias: {
      "@druzhok/shared": path.resolve(__dirname, "packages/shared/src"),
      "@druzhok/proxy": path.resolve(__dirname, "packages/proxy/src"),
      "@druzhok/core": path.resolve(__dirname, "packages/core/src"),
    },
  },
});
```

- [ ] **Step 6: Create .gitignore**

```
node_modules/
dist/
*.tsbuildinfo
.env
```

- [ ] **Step 7: Create packages/shared/package.json**

```json
{
  "name": "@druzhok/shared",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc"
  }
}
```

- [ ] **Step 8: Create packages/shared/tsconfig.json**

```json
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src",
    "composite": true
  },
  "include": ["src"]
}
```

- [ ] **Step 9: Create packages/proxy/package.json**

```json
{
  "name": "@druzhok/proxy",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "exports": {
    ".": "./dist/index.js",
    "./*": "./dist/*.js"
  },
  "dependencies": {
    "@druzhok/shared": "workspace:*",
    "fastify": "^5.3.0"
  }
}
```

- [ ] **Step 10: Create packages/proxy/tsconfig.json**

```json
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src",
    "composite": true
  },
  "include": ["src"],
  "references": [
    { "path": "../shared" }
  ]
}
```

- [ ] **Step 11: Create packages/core/package.json**

```json
{
  "name": "@druzhok/core",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc"
  },
  "exports": {
    ".": "./dist/index.js",
    "./*": "./dist/*.js"
  },
  "dependencies": {
    "@druzhok/shared": "workspace:*"
  }
}
```

- [ ] **Step 12: Create packages/core/tsconfig.json**

```json
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src",
    "composite": true
  },
  "include": ["src"],
  "references": [
    { "path": "../shared" }
  ]
}
```

- [ ] **Step 13: Install dependencies and verify build**

Run: `cd druzhok-v2 && pnpm install && pnpm build`
Expected: Clean install and successful (empty) build

- [ ] **Step 14: Commit**

```bash
git add druzhok-v2/
git commit -m "scaffold druzhok-v2 monorepo with shared, core, proxy packages"
```

---

### Task 2: Shared Types & Token Helpers

**Files:**
- Create: `packages/shared/src/types.ts`
- Create: `packages/shared/src/tokens.ts`
- Create: `packages/shared/src/index.ts`
- Create: `tests/shared/types.test.ts`
- Create: `tests/shared/tokens.test.ts`

- [ ] **Step 1: Write failing tests for token helpers**

```ts
// tests/shared/tokens.test.ts
import { describe, it, expect } from "vitest";
import {
  SILENT_REPLY_TOKEN,
  HEARTBEAT_TOKEN,
  isSilentReplyText,
  stripSilentToken,
  isHeartbeatOnly,
  stripHeartbeatToken,
} from "@druzhok/shared";

describe("isSilentReplyText", () => {
  it("matches exact NO_REPLY", () => {
    expect(isSilentReplyText("NO_REPLY")).toBe(true);
  });

  it("matches with surrounding whitespace", () => {
    expect(isSilentReplyText("  NO_REPLY  ")).toBe(true);
  });

  it("does not match NO_REPLY embedded in text", () => {
    expect(isSilentReplyText("Sure thing! NO_REPLY")).toBe(false);
  });

  it("returns false for undefined", () => {
    expect(isSilentReplyText(undefined)).toBe(false);
  });

  it("returns false for empty string", () => {
    expect(isSilentReplyText("")).toBe(false);
  });
});

describe("stripSilentToken", () => {
  it("strips trailing NO_REPLY", () => {
    expect(stripSilentToken("Some text NO_REPLY")).toBe("Some text");
  });

  it("strips trailing NO_REPLY with punctuation", () => {
    expect(stripSilentToken("Done. NO_REPLY")).toBe("Done.");
  });

  it("returns empty for NO_REPLY only", () => {
    expect(stripSilentToken("NO_REPLY")).toBe("");
  });

  it("returns text unchanged if no token", () => {
    expect(stripSilentToken("Hello world")).toBe("Hello world");
  });
});

describe("isHeartbeatOnly", () => {
  it("matches exact HEARTBEAT_OK", () => {
    expect(isHeartbeatOnly("HEARTBEAT_OK")).toBe(true);
  });

  it("matches with whitespace", () => {
    expect(isHeartbeatOnly("  HEARTBEAT_OK\n")).toBe(true);
  });

  it("does not match mixed content", () => {
    expect(isHeartbeatOnly("All good HEARTBEAT_OK")).toBe(false);
  });
});

describe("stripHeartbeatToken", () => {
  it("strips HEARTBEAT_OK from start", () => {
    expect(stripHeartbeatToken("HEARTBEAT_OK and more")).toBe("and more");
  });

  it("strips HEARTBEAT_OK from end", () => {
    expect(stripHeartbeatToken("Status fine HEARTBEAT_OK")).toBe("Status fine");
  });

  it("returns empty for HEARTBEAT_OK only", () => {
    expect(stripHeartbeatToken("HEARTBEAT_OK")).toBe("");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/shared/tokens.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement tokens.ts**

```ts
// packages/shared/src/tokens.ts
export const SILENT_REPLY_TOKEN = "NO_REPLY";
export const HEARTBEAT_TOKEN = "HEARTBEAT_OK";

export function isSilentReplyText(text: string | undefined): boolean {
  if (!text) return false;
  return /^\s*NO_REPLY\s*$/.test(text);
}

export function stripSilentToken(text: string, token: string = SILENT_REPLY_TOKEN): string {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return text.replace(new RegExp(`(?:^|\\s+)${escaped}\\s*$`), "").trim();
}

export function isHeartbeatOnly(text: string | undefined): boolean {
  if (!text) return false;
  return /^\s*HEARTBEAT_OK\s*$/.test(text);
}

export function stripHeartbeatToken(text: string): string {
  const token = HEARTBEAT_TOKEN;
  let result = text.trim();
  // Strip from start
  if (result.startsWith(token)) {
    result = result.slice(token.length).trimStart();
  }
  // Strip from end (with optional trailing punctuation)
  const endRegex = new RegExp(`${token}[^\\w]{0,4}$`);
  if (endRegex.test(result)) {
    const idx = result.lastIndexOf(token);
    result = result.slice(0, idx).trimEnd();
  }
  return result;
}
```

- [ ] **Step 4: Implement types.ts**

```ts
// packages/shared/src/types.ts
export type ReplyPayload = {
  text?: string;
  mediaUrl?: string;
  mediaUrls?: string[];
  isReasoning?: boolean;
  isError?: boolean;
  isSilent?: boolean;
  replyToId?: number;
  audioAsVoice?: boolean;
};

export type InboundContext = {
  body: string;
  from: string;
  chatId: string;
  chatType: "direct" | "group";
  senderId: string;
  senderName: string;
  messageId: number;
  replyTo?: ReplyContext;
  media?: MediaRef[];
  sessionKey: string;
  timestamp: number;
};

export type ReplyContext = {
  messageId: number;
  senderId: string;
  senderName: string;
  body: string;
};

export type MediaRef = {
  path: string;
  contentType: string;
  filename?: string;
};

export type DeliveryResult = {
  delivered: boolean;
  messageId?: number;
  error?: string;
};

export type DraftStreamOpts = {
  replyToMessageId?: number;
  threadId?: number;
  minInitialChars?: number;
};
```

- [ ] **Step 5: Write types test**

```ts
// tests/shared/types.test.ts
import { describe, it, expect } from "vitest";
import type { ReplyPayload, InboundContext, DeliveryResult } from "@druzhok/shared";

describe("types", () => {
  it("ReplyPayload accepts minimal payload", () => {
    const payload: ReplyPayload = { text: "hello" };
    expect(payload.text).toBe("hello");
    expect(payload.isReasoning).toBeUndefined();
  });

  it("ReplyPayload accepts full payload", () => {
    const payload: ReplyPayload = {
      text: "response",
      mediaUrl: "file:///tmp/img.png",
      mediaUrls: ["file:///tmp/img.png"],
      isReasoning: false,
      isError: false,
      isSilent: false,
      replyToId: 42,
      audioAsVoice: true,
    };
    expect(payload.replyToId).toBe(42);
  });

  it("InboundContext has required fields", () => {
    const ctx: InboundContext = {
      body: "hello",
      from: "telegram:dm:123",
      chatId: "123",
      chatType: "direct",
      senderId: "456",
      senderName: "Igor",
      messageId: 1,
      sessionKey: "telegram:dm:123",
      timestamp: Date.now(),
    };
    expect(ctx.chatType).toBe("direct");
  });
});
```

- [ ] **Step 6: Create barrel export**

```ts
// packages/shared/src/index.ts
export * from "./types.js";
export * from "./tokens.js";
```

- [ ] **Step 7: Run all shared tests**

Run: `cd druzhok-v2 && pnpm build && pnpm test -- tests/shared/`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add packages/shared/ tests/shared/
git commit -m "add shared types and token helpers"
```

---

### Task 3: Proxy Config & Auth

**Files:**
- Create: `packages/proxy/src/config.ts`
- Create: `packages/proxy/src/auth.ts`
- Create: `tests/proxy/auth.test.ts`

- [ ] **Step 1: Write failing auth tests**

```ts
// tests/proxy/auth.test.ts
import { describe, it, expect } from "vitest";
import { createAuthenticator, type InstanceRegistry } from "@druzhok/proxy/auth.js";

const registry: InstanceRegistry = {
  instances: {
    key_abc: { name: "test-bot", tier: "default", enabled: true },
    key_disabled: { name: "disabled-bot", tier: "default", enabled: false },
  },
};

describe("createAuthenticator", () => {
  const auth = createAuthenticator(registry);

  it("accepts valid enabled key", () => {
    const result = auth.validate("key_abc");
    expect(result).toEqual({
      ok: true,
      instance: { name: "test-bot", tier: "default", enabled: true },
    });
  });

  it("rejects unknown key", () => {
    const result = auth.validate("key_unknown");
    expect(result).toEqual({ ok: false, reason: "unknown_key" });
  });

  it("rejects disabled key", () => {
    const result = auth.validate("key_disabled");
    expect(result).toEqual({ ok: false, reason: "disabled" });
  });

  it("extracts key from Bearer header", () => {
    expect(auth.extractKey("Bearer key_abc")).toBe("key_abc");
  });

  it("returns null for missing header", () => {
    expect(auth.extractKey(undefined)).toBeNull();
    expect(auth.extractKey("")).toBeNull();
  });

  it("returns null for non-Bearer header", () => {
    expect(auth.extractKey("Basic abc123")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd druzhok-v2 && pnpm test -- tests/proxy/auth.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement config.ts**

```ts
// packages/proxy/src/config.ts
import { readFileSync } from "node:fs";

export type ProxyConfig = {
  port: number;
  providers: {
    anthropic?: { apiKey: string };
    openai?: { apiKey: string };
    nebius?: { apiKey: string; baseUrl: string };
  };
  registryPath: string;
};

export function loadProxyConfig(): ProxyConfig {
  return {
    port: parseInt(process.env.DRUZHOK_PROXY_PORT ?? "8080", 10),
    providers: {
      anthropic: process.env.ANTHROPIC_API_KEY
        ? { apiKey: process.env.ANTHROPIC_API_KEY }
        : undefined,
      openai: process.env.OPENAI_API_KEY
        ? { apiKey: process.env.OPENAI_API_KEY }
        : undefined,
      nebius: process.env.NEBIUS_API_KEY
        ? {
            apiKey: process.env.NEBIUS_API_KEY,
            baseUrl:
              process.env.NEBIUS_BASE_URL ?? "https://api.studio.nebius.com/v1/",
          }
        : undefined,
    },
    registryPath:
      process.env.DRUZHOK_PROXY_REGISTRY_PATH ?? "/etc/druzhok/instances.json",
  };
}

export type InstanceEntry = {
  name: string;
  tier: string;
  enabled: boolean;
};

export type InstanceRegistry = {
  instances: Record<string, InstanceEntry>;
};

export function loadRegistry(path: string): InstanceRegistry {
  try {
    const raw = readFileSync(path, "utf-8");
    return JSON.parse(raw) as InstanceRegistry;
  } catch {
    return { instances: {} };
  }
}
```

- [ ] **Step 4: Implement auth.ts**

```ts
// packages/proxy/src/auth.ts
export type { InstanceEntry, InstanceRegistry } from "./config.js";
import type { InstanceEntry, InstanceRegistry } from "./config.js";

export type AuthResult =
  | { ok: true; instance: InstanceEntry }
  | { ok: false; reason: "unknown_key" | "disabled" };

export type Authenticator = {
  validate(key: string): AuthResult;
  extractKey(header: string | undefined): string | null;
};

export function createAuthenticator(registry: InstanceRegistry): Authenticator {
  return {
    validate(key: string): AuthResult {
      const instance = registry.instances[key];
      if (!instance) {
        return { ok: false, reason: "unknown_key" };
      }
      if (!instance.enabled) {
        return { ok: false, reason: "disabled" };
      }
      return { ok: true, instance };
    },

    extractKey(header: string | undefined): string | null {
      if (!header) return null;
      const match = header.match(/^Bearer\s+(\S+)$/i);
      return match?.[1] ?? null;
    },
  };
}
```

- [ ] **Step 5: Run auth tests**

Run: `cd druzhok-v2 && pnpm build && pnpm test -- tests/proxy/auth.test.ts`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add packages/proxy/src/config.ts packages/proxy/src/auth.ts tests/proxy/auth.test.ts
git commit -m "add proxy config loading and auth"
```

---

### Task 4: Rate Limiter

**Files:**
- Create: `packages/proxy/src/rate-limit.ts`
- Create: `tests/proxy/rate-limit.test.ts`

- [ ] **Step 1: Write failing rate limiter tests**

```ts
// tests/proxy/rate-limit.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { createRateLimiter, type RateLimitTiers } from "@druzhok/proxy/rate-limit.js";

const tiers: RateLimitTiers = {
  default: { requestsPerMinute: 60 },
  limited: { requestsPerMinute: 3 },
};

describe("createRateLimiter", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  it("allows requests under the limit", () => {
    const limiter = createRateLimiter(tiers);
    const result = limiter.check("key1", "default");
    expect(result).toEqual({ allowed: true });
  });

  it("blocks requests over the limit", () => {
    const limiter = createRateLimiter(tiers);
    for (let i = 0; i < 3; i++) {
      limiter.check("key1", "limited");
    }
    const result = limiter.check("key1", "limited");
    expect(result.allowed).toBe(false);
    expect(result.retryAfter).toBeGreaterThan(0);
  });

  it("resets after window expires", () => {
    const limiter = createRateLimiter(tiers);
    for (let i = 0; i < 3; i++) {
      limiter.check("key1", "limited");
    }
    expect(limiter.check("key1", "limited").allowed).toBe(false);

    vi.advanceTimersByTime(60_000); // advance 1 minute

    expect(limiter.check("key1", "limited").allowed).toBe(true);
  });

  it("tracks keys independently", () => {
    const limiter = createRateLimiter(tiers);
    for (let i = 0; i < 3; i++) {
      limiter.check("key1", "limited");
    }
    expect(limiter.check("key1", "limited").allowed).toBe(false);
    expect(limiter.check("key2", "limited").allowed).toBe(true);
  });

  it("falls back to default tier for unknown tier", () => {
    const limiter = createRateLimiter(tiers);
    const result = limiter.check("key1", "unknown_tier");
    expect(result.allowed).toBe(true);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/proxy/rate-limit.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement rate-limit.ts**

```ts
// packages/proxy/src/rate-limit.ts
export type TierConfig = {
  requestsPerMinute: number;
};

export type RateLimitTiers = Record<string, TierConfig>;

export type RateLimitResult =
  | { allowed: true }
  | { allowed: false; retryAfter: number };

type Bucket = {
  count: number;
  windowStart: number;
};

export type RateLimiter = {
  check(key: string, tier: string): RateLimitResult;
};

export function createRateLimiter(tiers: RateLimitTiers): RateLimiter {
  const buckets = new Map<string, Bucket>();
  const WINDOW_MS = 60_000;

  return {
    check(key: string, tier: string): RateLimitResult {
      const tierConfig = tiers[tier] ?? tiers["default"];
      if (!tierConfig) {
        return { allowed: true };
      }

      const now = Date.now();
      let bucket = buckets.get(key);

      if (!bucket || now - bucket.windowStart >= WINDOW_MS) {
        bucket = { count: 0, windowStart: now };
        buckets.set(key, bucket);
      }

      if (bucket.count >= tierConfig.requestsPerMinute) {
        const retryAfter = Math.ceil(
          (bucket.windowStart + WINDOW_MS - now) / 1000
        );
        return { allowed: false, retryAfter: Math.max(1, retryAfter) };
      }

      bucket.count++;
      return { allowed: true };
    },
  };
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm build && pnpm test -- tests/proxy/rate-limit.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/proxy/src/rate-limit.ts tests/proxy/rate-limit.test.ts
git commit -m "add token bucket rate limiter"
```

---

### Task 5: Provider Router

**Files:**
- Create: `packages/proxy/src/providers/router.ts`
- Create: `packages/proxy/src/providers/openai-compat.ts`
- Create: `packages/proxy/src/providers/anthropic.ts`
- Create: `tests/proxy/router.test.ts`
- Create: `tests/proxy/anthropic.test.ts`

- [ ] **Step 1: Write failing router tests**

```ts
// tests/proxy/router.test.ts
import { describe, it, expect } from "vitest";
import { parseModelId, resolveProvider } from "@druzhok/proxy/providers/router.js";

describe("parseModelId", () => {
  it("parses anthropic/claude-sonnet-4-20250514", () => {
    expect(parseModelId("anthropic/claude-sonnet-4-20250514")).toEqual({
      provider: "anthropic",
      model: "claude-sonnet-4-20250514",
    });
  });

  it("parses nebius/deepseek-r1", () => {
    expect(parseModelId("nebius/deepseek-r1")).toEqual({
      provider: "nebius",
      model: "deepseek-r1",
    });
  });

  it("parses openai/gpt-4o", () => {
    expect(parseModelId("openai/gpt-4o")).toEqual({
      provider: "openai",
      model: "gpt-4o",
    });
  });

  it("treats unprefixed model as default provider", () => {
    expect(parseModelId("gpt-4o")).toEqual({
      provider: "default",
      model: "gpt-4o",
    });
  });
});

describe("resolveProvider", () => {
  const providers = {
    anthropic: { apiKey: "sk-ant-test" },
    openai: { apiKey: "sk-test" },
    nebius: { apiKey: "nb-test", baseUrl: "https://api.nebius.com/v1/" },
  };

  it("resolves anthropic provider", () => {
    const result = resolveProvider("anthropic", providers);
    expect(result).toEqual({
      type: "anthropic",
      apiKey: "sk-ant-test",
      baseUrl: "https://api.anthropic.com",
    });
  });

  it("resolves nebius as openai-compat", () => {
    const result = resolveProvider("nebius", providers);
    expect(result).toEqual({
      type: "openai-compat",
      apiKey: "nb-test",
      baseUrl: "https://api.nebius.com/v1/",
    });
  });

  it("resolves openai as openai-compat", () => {
    const result = resolveProvider("openai", providers);
    expect(result).toEqual({
      type: "openai-compat",
      apiKey: "sk-test",
      baseUrl: "https://api.openai.com/v1/",
    });
  });

  it("returns null for unconfigured provider", () => {
    expect(resolveProvider("google", providers)).toBeNull();
  });

  it("resolves default to first configured provider", () => {
    const result = resolveProvider("default", providers);
    expect(result).not.toBeNull();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/proxy/router.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement router.ts**

```ts
// packages/proxy/src/providers/router.ts
import type { ProxyConfig } from "../config.js";

export type ParsedModelId = {
  provider: string;
  model: string;
};

export function parseModelId(modelId: string): ParsedModelId {
  const slashIndex = modelId.indexOf("/");
  if (slashIndex === -1) {
    return { provider: "default", model: modelId };
  }
  return {
    provider: modelId.slice(0, slashIndex),
    model: modelId.slice(slashIndex + 1),
  };
}

export type ResolvedProvider =
  | { type: "anthropic"; apiKey: string; baseUrl: string }
  | { type: "openai-compat"; apiKey: string; baseUrl: string };

export function resolveProvider(
  providerName: string,
  providers: ProxyConfig["providers"]
): ResolvedProvider | null {
  if (providerName === "anthropic" && providers.anthropic) {
    return {
      type: "anthropic",
      apiKey: providers.anthropic.apiKey,
      baseUrl: "https://api.anthropic.com",
    };
  }

  if (providerName === "openai" && providers.openai) {
    return {
      type: "openai-compat",
      apiKey: providers.openai.apiKey,
      baseUrl: "https://api.openai.com/v1/",
    };
  }

  if (providerName === "nebius" && providers.nebius) {
    return {
      type: "openai-compat",
      apiKey: providers.nebius.apiKey,
      baseUrl: providers.nebius.baseUrl,
    };
  }

  // Default: try openai → anthropic → nebius
  if (providerName === "default") {
    if (providers.openai) {
      return resolveProvider("openai", providers);
    }
    if (providers.anthropic) {
      return resolveProvider("anthropic", providers);
    }
    if (providers.nebius) {
      return resolveProvider("nebius", providers);
    }
  }

  return null;
}
```

- [ ] **Step 4: Implement openai-compat.ts (passthrough)**

```ts
// packages/proxy/src/providers/openai-compat.ts

export type OpenAICompatForwardOpts = {
  baseUrl: string;
  apiKey: string;
  model: string;
  body: unknown;
  stream: boolean;
};

export async function forwardToOpenAICompat(
  opts: OpenAICompatForwardOpts
): Promise<Response> {
  const url = `${opts.baseUrl.replace(/\/$/, "")}/chat/completions`;
  const body = {
    ...(opts.body as Record<string, unknown>),
    model: opts.model,
  };

  return fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${opts.apiKey}`,
    },
    body: JSON.stringify(body),
  });
}

export async function forwardEmbeddingsToOpenAICompat(opts: {
  baseUrl: string;
  apiKey: string;
  body: unknown;
}): Promise<Response> {
  const url = `${opts.baseUrl.replace(/\/$/, "")}/embeddings`;

  return fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${opts.apiKey}`,
    },
    body: JSON.stringify(opts.body),
  });
}
```

- [ ] **Step 5: Write failing Anthropic translation tests**

```ts
// tests/proxy/anthropic.test.ts
import { describe, it, expect } from "vitest";
import {
  translateOpenAIToAnthropic,
  translateAnthropicStreamEvent,
  translateAnthropicResponse,
  createStreamState,
} from "@druzhok/proxy/providers/anthropic.js";

describe("translateOpenAIToAnthropic", () => {
  it("extracts system message", () => {
    const openaiBody = {
      model: "claude-sonnet-4-20250514",
      messages: [
        { role: "system", content: "You are helpful" },
        { role: "user", content: "Hello" },
      ],
      stream: true,
    };
    const result = translateOpenAIToAnthropic(openaiBody);
    expect(result.system).toBe("You are helpful");
    expect(result.messages).toEqual([
      { role: "user", content: "Hello" },
    ]);
    expect(result.model).toBe("claude-sonnet-4-20250514");
    expect(result.max_tokens).toBeGreaterThan(0);
    expect(result.stream).toBe(true);
  });

  it("handles no system message", () => {
    const openaiBody = {
      model: "claude-sonnet-4-20250514",
      messages: [{ role: "user", content: "Hello" }],
    };
    const result = translateOpenAIToAnthropic(openaiBody);
    expect(result.system).toBeUndefined();
    expect(result.messages).toEqual([
      { role: "user", content: "Hello" },
    ]);
  });

  it("passes through tools", () => {
    const openaiBody = {
      model: "claude-sonnet-4-20250514",
      messages: [{ role: "user", content: "Hello" }],
      tools: [{ type: "function", function: { name: "test" } }],
    };
    const result = translateOpenAIToAnthropic(openaiBody);
    expect(result.tools).toBeDefined();
  });
});

describe("translateAnthropicStreamEvent", () => {
  it("translates content_block_delta to OpenAI format", () => {
    const event = {
      type: "content_block_delta",
      delta: { type: "text_delta", text: "Hello" },
    };
    const result = translateAnthropicStreamEvent(event);
    expect(result).toEqual({
      choices: [{ index: 0, delta: { content: "Hello" } }],
    });
  });

  it("translates message_stop to done", () => {
    const event = { type: "message_stop" };
    const result = translateAnthropicStreamEvent(event);
    expect(result).toBe("[DONE]");
  });

  it("returns null for non-content events", () => {
    const event = { type: "ping" };
    const result = translateAnthropicStreamEvent(event);
    expect(result).toBeNull();
  });

  it("translates tool_use content_block_start", () => {
    const state = createStreamState();
    const event = {
      type: "content_block_start",
      content_block: { type: "tool_use", id: "call_1", name: "read" },
    };
    const result = translateAnthropicStreamEvent(event as any, state);
    expect(result).toEqual({
      choices: [{
        index: 0,
        delta: {
          tool_calls: [{
            index: 0,
            id: "call_1",
            type: "function",
            function: { name: "read", arguments: "" },
          }],
        },
      }],
    });
  });

  it("translates input_json_delta", () => {
    const state = createStreamState();
    state.currentToolIndex = 0;
    const event = {
      type: "content_block_delta",
      delta: { type: "input_json_delta", partial_json: '{"path":' },
    };
    const result = translateAnthropicStreamEvent(event as any, state);
    expect(result).toEqual({
      choices: [{
        index: 0,
        delta: {
          tool_calls: [{
            index: 0,
            function: { arguments: '{"path":' },
          }],
        },
      }],
    });
  });
});

describe("translateAnthropicResponse", () => {
  it("translates text response", () => {
    const response = {
      id: "msg_1",
      model: "claude-sonnet-4-20250514",
      content: [{ type: "text", text: "Hello" }],
      stop_reason: "end_turn",
      usage: { input_tokens: 10, output_tokens: 5 },
    };
    const result = translateAnthropicResponse(response);
    expect(result.id).toBe("msg_1");
    expect(result.model).toBe("claude-sonnet-4-20250514");
    expect((result.choices as any)[0].message.content).toBe("Hello");
    expect((result.choices as any)[0].finish_reason).toBe("stop");
  });

  it("translates tool_use response", () => {
    const response = {
      id: "msg_2",
      model: "claude-sonnet-4-20250514",
      content: [
        { type: "text", text: "Let me read that." },
        { type: "tool_use", id: "call_1", name: "read", input: { path: "/tmp" } },
      ],
      stop_reason: "tool_use",
      usage: { input_tokens: 10, output_tokens: 20 },
    };
    const result = translateAnthropicResponse(response);
    const choice = (result.choices as any)[0];
    expect(choice.finish_reason).toBe("tool_calls");
    expect(choice.message.tool_calls).toHaveLength(1);
    expect(choice.message.tool_calls[0].function.name).toBe("read");
    expect(choice.message.tool_calls[0].function.arguments).toBe('{"path":"/tmp"}');
  });
});
```

- [ ] **Step 6: Run Anthropic tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/proxy/anthropic.test.ts`
Expected: FAIL

- [ ] **Step 7: Implement anthropic.ts**

```ts
// packages/proxy/src/providers/anthropic.ts

const DEFAULT_MAX_TOKENS = 8192;

type OpenAIMessage = {
  role: string;
  content: string | unknown[];
};

type AnthropicRequest = {
  model: string;
  messages: OpenAIMessage[];
  system?: string;
  max_tokens: number;
  stream?: boolean;
  tools?: unknown[];
  temperature?: number;
  top_p?: number;
};

export function translateOpenAIToAnthropic(
  body: Record<string, unknown>
): AnthropicRequest {
  const messages = (body.messages as OpenAIMessage[]) ?? [];
  const systemMessages = messages.filter((m) => m.role === "system");
  const nonSystemMessages = messages.filter((m) => m.role !== "system");

  const systemText = systemMessages
    .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
    .join("\n\n");

  const result: AnthropicRequest = {
    model: body.model as string,
    messages: nonSystemMessages,
    max_tokens: (body.max_tokens as number) ?? DEFAULT_MAX_TOKENS,
    stream: body.stream as boolean | undefined,
  };

  if (systemText) {
    result.system = systemText;
  }
  if (body.tools) {
    result.tools = body.tools as unknown[];
  }
  if (body.temperature !== undefined) {
    result.temperature = body.temperature as number;
  }
  if (body.top_p !== undefined) {
    result.top_p = body.top_p as number;
  }

  return result;
}

export type AnthropicStreamEvent = {
  type: string;
  delta?: { type?: string; text?: string };
  [key: string]: unknown;
};

type OpenAIStreamChunk = {
  choices: Array<{ index: number; delta: { content?: string; role?: string } }>;
};

// Track tool call state across streaming events
export type StreamTranslationState = {
  currentToolIndex: number;
  toolCallId: string | null;
};

export function createStreamState(): StreamTranslationState {
  return { currentToolIndex: -1, toolCallId: null };
}

export function translateAnthropicStreamEvent(
  event: AnthropicStreamEvent,
  state?: StreamTranslationState
): OpenAIStreamChunk | "[DONE]" | null {
  switch (event.type) {
    case "content_block_delta":
      if (event.delta?.type === "text_delta" && event.delta.text) {
        return {
          choices: [{ index: 0, delta: { content: event.delta.text } }],
        };
      }
      // Tool call argument streaming
      if (event.delta?.type === "input_json_delta" && state) {
        return {
          choices: [{
            index: 0,
            delta: {
              tool_calls: [{
                index: state.currentToolIndex,
                function: { arguments: (event.delta as Record<string, string>).partial_json ?? "" },
              }],
            },
          }],
        };
      }
      return null;

    case "content_block_start": {
      const block = (event as Record<string, unknown>).content_block as Record<string, unknown> | undefined;
      if (block?.type === "tool_use" && state) {
        state.currentToolIndex++;
        state.toolCallId = (block.id as string) ?? null;
        return {
          choices: [{
            index: 0,
            delta: {
              tool_calls: [{
                index: state.currentToolIndex,
                id: block.id as string,
                type: "function",
                function: { name: block.name as string, arguments: "" },
              }],
            },
          }],
        };
      }
      return null;
    }

    case "message_start":
      return {
        choices: [{ index: 0, delta: { role: "assistant" } }],
      };

    case "message_stop":
      return "[DONE]";

    default:
      return null;
  }
}

export function translateAnthropicResponse(
  response: Record<string, unknown>
): Record<string, unknown> {
  const content = (response.content as Array<Record<string, unknown>>) ?? [];
  const textParts = content
    .filter((b) => b.type === "text")
    .map((b) => b.text as string);
  const toolCalls = content
    .filter((b) => b.type === "tool_use")
    .map((b, i) => ({
      index: i,
      id: b.id as string,
      type: "function",
      function: {
        name: b.name as string,
        arguments: JSON.stringify(b.input),
      },
    }));

  const message: Record<string, unknown> = {
    role: "assistant",
    content: textParts.join("") || null,
  };
  if (toolCalls.length > 0) {
    message.tool_calls = toolCalls;
  }

  return {
    id: response.id ?? `chatcmpl-${Date.now()}`,
    object: "chat.completion",
    model: response.model,
    choices: [{
      index: 0,
      message,
      finish_reason: response.stop_reason === "end_turn" ? "stop"
        : response.stop_reason === "tool_use" ? "tool_calls"
        : (response.stop_reason as string) ?? "stop",
    }],
    usage: response.usage,
  };
}

export async function forwardToAnthropic(opts: {
  apiKey: string;
  baseUrl: string;
  model: string;
  body: unknown;
  stream: boolean;
}): Promise<Response> {
  const anthropicBody = translateOpenAIToAnthropic({
    ...(opts.body as Record<string, unknown>),
    model: opts.model,
    stream: opts.stream,
  });

  return fetch(`${opts.baseUrl}/v1/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": opts.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify(anthropicBody),
  });
}
```

- [ ] **Step 8: Run all provider tests**

Run: `cd druzhok-v2 && pnpm build && pnpm test -- tests/proxy/`
Expected: All PASS

- [ ] **Step 9: Commit**

```bash
git add packages/proxy/src/providers/ tests/proxy/router.test.ts tests/proxy/anthropic.test.ts
git commit -m "add provider router with Anthropic translation"
```

---

### Task 6: Proxy Server (Fastify)

**Files:**
- Create: `packages/proxy/src/server.ts`
- Create: `packages/proxy/src/health.ts`
- Create: `packages/proxy/src/index.ts`
- Create: `tests/proxy/server.integration.test.ts`

- [ ] **Step 1: Implement health.ts**

```ts
// packages/proxy/src/health.ts
import type { FastifyInstance } from "fastify";

export function registerHealthRoute(app: FastifyInstance): void {
  app.get("/health", async () => {
    return { status: "ok", timestamp: new Date().toISOString() };
  });
}
```

- [ ] **Step 2: Implement server.ts**

```ts
// packages/proxy/src/server.ts
import Fastify, { type FastifyInstance, type FastifyRequest, type FastifyReply } from "fastify";
import { createAuthenticator } from "./auth.js";
import { loadProxyConfig, loadRegistry, type ProxyConfig, type InstanceRegistry } from "./config.js";
import { registerHealthRoute } from "./health.js";
import { createRateLimiter, type RateLimiter } from "./rate-limit.js";
import { parseModelId, resolveProvider } from "./providers/router.js";
import { forwardToOpenAICompat, forwardEmbeddingsToOpenAICompat } from "./providers/openai-compat.js";
import { forwardToAnthropic, translateAnthropicStreamEvent, translateAnthropicResponse, createStreamState, type AnthropicStreamEvent } from "./providers/anthropic.js";
import { randomUUID } from "node:crypto";

const DEFAULT_TIERS = {
  default: { requestsPerMinute: 60 },
  limited: { requestsPerMinute: 20 },
};

export async function createProxyServer(overrides?: {
  config?: Partial<ProxyConfig>;
  registry?: InstanceRegistry;
}): Promise<FastifyInstance> {
  const config = { ...loadProxyConfig(), ...overrides?.config };
  const registry = overrides?.registry ?? loadRegistry(config.registryPath);
  const auth = createAuthenticator(registry);
  const rateLimiter = createRateLimiter(DEFAULT_TIERS);

  const app = Fastify({ logger: true });

  registerHealthRoute(app);

  // Add X-Request-Id to all requests
  app.addHook("onRequest", async (request, reply) => {
    const requestId = randomUUID();
    reply.header("X-Request-Id", requestId);
    (request as Record<string, unknown>).__requestId = requestId;
  });

  // Auth + rate limit hook for /v1/* routes
  app.addHook("preHandler", async (request: FastifyRequest, reply: FastifyReply) => {
    if (!request.url.startsWith("/v1/")) return;

    const key = auth.extractKey(request.headers.authorization);
    if (!key) {
      reply.code(401).send({ error: "Missing or invalid Authorization header" });
      return;
    }

    const authResult = auth.validate(key);
    if (!authResult.ok) {
      reply.code(401).send({ error: `Unauthorized: ${authResult.reason}` });
      return;
    }

    const rateResult = rateLimiter.check(key, authResult.instance.tier);
    if (!rateResult.allowed) {
      reply.code(429).header("Retry-After", String(rateResult.retryAfter))
        .send({ error: "Rate limit exceeded" });
      return;
    }

    // Attach instance info for downstream use
    (request as Record<string, unknown>).__instance = authResult.instance;
  });

  // POST /v1/chat/completions
  app.post("/v1/chat/completions", async (request, reply) => {
    const body = request.body as Record<string, unknown>;
    const modelId = body.model as string;
    if (!modelId) {
      reply.code(400).send({ error: "Missing model field" });
      return;
    }

    const parsed = parseModelId(modelId);
    const provider = resolveProvider(parsed.provider, config.providers);
    if (!provider) {
      reply.code(400).send({ error: `No provider configured for: ${parsed.provider}` });
      return;
    }

    const isStream = body.stream === true;

    try {
      if (provider.type === "openai-compat") {
        const upstream = await forwardToOpenAICompat({
          baseUrl: provider.baseUrl,
          apiKey: provider.apiKey,
          model: parsed.model,
          body,
          stream: isStream,
        });

        reply.code(upstream.status);
        for (const [k, v] of upstream.headers) {
          if (k.toLowerCase() !== "transfer-encoding") {
            reply.header(k, v);
          }
        }

        if (isStream && upstream.body) {
          reply.header("content-type", "text/event-stream");
          return reply.send(upstream.body);
        }

        const responseBody = await upstream.json();
        return reply.send(responseBody);
      }

      if (provider.type === "anthropic") {
        const upstream = await forwardToAnthropic({
          apiKey: provider.apiKey,
          baseUrl: provider.baseUrl,
          model: parsed.model,
          body,
          stream: isStream,
        });

        if (!isStream) {
          // Non-streaming: translate Anthropic response to OpenAI format
          const anthropicResponse = await upstream.json() as Record<string, unknown>;
          reply.send(translateAnthropicResponse(anthropicResponse));
          return;
        }

        // Streaming: translate Anthropic SSE to OpenAI SSE
        reply.raw.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });

        const reader = upstream.body?.getReader();
        if (!reader) {
          reply.raw.end();
          return;
        }

        const decoder = new TextDecoder();
        const streamState = createStreamState();
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice(6).trim();
            if (data === "[DONE]") {
              reply.raw.write("data: [DONE]\n\n");
              continue;
            }
            try {
              const event = JSON.parse(data) as AnthropicStreamEvent;
              const translated = translateAnthropicStreamEvent(event, streamState);
              if (translated === "[DONE]") {
                reply.raw.write("data: [DONE]\n\n");
              } else if (translated) {
                reply.raw.write(`data: ${JSON.stringify(translated)}\n\n`);
              }
            } catch {
              // Skip unparseable lines
            }
          }
        }

        reply.raw.end();
        return;
      }
    } catch (err) {
      reply.code(502).send({
        error: `Provider error: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
  });

  // POST /v1/embeddings (passthrough to OpenAI-compat only)
  app.post("/v1/embeddings", async (request, reply) => {
    // Use OpenAI or Nebius for embeddings (both OpenAI-compatible)
    const provider = config.providers.openai
      ? { apiKey: config.providers.openai.apiKey, baseUrl: "https://api.openai.com/v1/" }
      : config.providers.nebius
        ? { apiKey: config.providers.nebius.apiKey, baseUrl: config.providers.nebius.baseUrl }
        : null;

    if (!provider) {
      reply.code(400).send({ error: "No embedding provider configured" });
      return;
    }

    try {
      const upstream = await forwardEmbeddingsToOpenAICompat({
        baseUrl: provider.baseUrl,
        apiKey: provider.apiKey,
        body: request.body,
      });
      const responseBody = await upstream.json();
      reply.code(upstream.status).send(responseBody);
    } catch (err) {
      reply.code(502).send({
        error: `Embedding error: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
  });

  return app;
}
```

- [ ] **Step 3: Implement index.ts entry point**

```ts
// packages/proxy/src/index.ts
import { createProxyServer } from "./server.js";
import { loadProxyConfig } from "./config.js";

async function main() {
  const config = loadProxyConfig();
  const server = await createProxyServer();

  await server.listen({ port: config.port, host: "0.0.0.0" });
  console.log(`Druzhok proxy listening on port ${config.port}`);
}

main().catch((err) => {
  console.error("Failed to start proxy:", err);
  process.exit(1);
});
```

- [ ] **Step 4: Write integration test**

```ts
// tests/proxy/server.integration.test.ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import type { FastifyInstance } from "fastify";
import { createProxyServer } from "@druzhok/proxy/server.js";

describe("proxy server", () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    app = await createProxyServer({
      registry: {
        instances: {
          test_key: { name: "test", tier: "default", enabled: true },
        },
      },
      config: {
        port: 0,
        providers: {},
        registryPath: "",
      },
    });
  });

  afterAll(async () => {
    await app.close();
  });

  it("GET /health returns ok", async () => {
    const res = await app.inject({ method: "GET", url: "/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toHaveProperty("status", "ok");
  });

  it("POST /v1/chat/completions without auth returns 401", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      payload: { model: "test", messages: [] },
    });
    expect(res.statusCode).toBe(401);
  });

  it("POST /v1/chat/completions with invalid key returns 401", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      headers: { authorization: "Bearer wrong_key" },
      payload: { model: "test", messages: [] },
    });
    expect(res.statusCode).toBe(401);
  });

  it("POST /v1/chat/completions with valid key but no provider returns 400", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      headers: { authorization: "Bearer test_key" },
      payload: { model: "openai/gpt-4o", messages: [] },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toContain("No provider configured");
  });

  it("POST /v1/chat/completions with missing model returns 400", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/chat/completions",
      headers: { authorization: "Bearer test_key" },
      payload: { messages: [] },
    });
    expect(res.statusCode).toBe(400);
  });

  it("POST /v1/embeddings without embedding provider returns 400", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/embeddings",
      headers: { authorization: "Bearer test_key" },
      payload: { input: "hello", model: "text-embedding-3-small" },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toContain("No embedding provider");
  });
});
```

- [ ] **Step 5: Run integration tests**

Run: `cd druzhok-v2 && pnpm build && pnpm test -- tests/proxy/server.integration.test.ts`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add packages/proxy/src/ tests/proxy/server.integration.test.ts
git commit -m "add proxy server with auth, rate limiting, provider routing"
```

---

### Task 7: Core Config & Session Key

**Files:**
- Create: `packages/core/src/config/config.ts`
- Create: `packages/core/src/session/session-key.ts`
- Create: `packages/core/src/index.ts`
- Create: `tests/core/config.test.ts`
- Create: `tests/core/session-key.test.ts`

- [ ] **Step 1: Write failing session key tests**

```ts
// tests/core/session-key.test.ts
import { describe, it, expect } from "vitest";
import {
  buildSessionKey,
  parseSessionKey,
  isHeartbeatSession,
} from "@druzhok/core/session/session-key.js";

describe("buildSessionKey", () => {
  it("builds DM session key", () => {
    expect(buildSessionKey({ channel: "telegram", chatType: "direct", chatId: "123" }))
      .toBe("telegram:dm:123");
  });

  it("builds group session key", () => {
    expect(buildSessionKey({ channel: "telegram", chatType: "group", chatId: "456" }))
      .toBe("telegram:group:456");
  });

  it("builds topic session key", () => {
    expect(buildSessionKey({ channel: "telegram", chatType: "group", chatId: "456", topicId: "7" }))
      .toBe("telegram:group:456:topic:7");
  });
});

describe("parseSessionKey", () => {
  it("parses DM key", () => {
    expect(parseSessionKey("telegram:dm:123")).toEqual({
      channel: "telegram",
      chatType: "direct",
      chatId: "123",
    });
  });

  it("parses group key", () => {
    expect(parseSessionKey("telegram:group:456")).toEqual({
      channel: "telegram",
      chatType: "group",
      chatId: "456",
    });
  });

  it("parses topic key", () => {
    expect(parseSessionKey("telegram:group:456:topic:7")).toEqual({
      channel: "telegram",
      chatType: "group",
      chatId: "456",
      topicId: "7",
    });
  });

  it("returns null for invalid key", () => {
    expect(parseSessionKey("garbage")).toBeNull();
  });
});

describe("isHeartbeatSession", () => {
  it("identifies heartbeat session", () => {
    expect(isHeartbeatSession("system:heartbeat")).toBe(true);
  });

  it("rejects normal session", () => {
    expect(isHeartbeatSession("telegram:dm:123")).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/core/session-key.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement session-key.ts**

```ts
// packages/core/src/session/session-key.ts

export const HEARTBEAT_SESSION_KEY = "system:heartbeat";

export type SessionKeyParts = {
  channel: string;
  chatType: "direct" | "group";
  chatId: string;
  topicId?: string;
};

export function buildSessionKey(parts: {
  channel: string;
  chatType: "direct" | "group";
  chatId: string;
  topicId?: string;
}): string {
  const typeSegment = parts.chatType === "direct" ? "dm" : "group";
  let key = `${parts.channel}:${typeSegment}:${parts.chatId}`;
  if (parts.topicId) {
    key += `:topic:${parts.topicId}`;
  }
  return key;
}

export function parseSessionKey(key: string): SessionKeyParts | null {
  // telegram:dm:123
  const dmMatch = key.match(/^(\w+):dm:(\w+)$/);
  if (dmMatch) {
    return { channel: dmMatch[1], chatType: "direct", chatId: dmMatch[2] };
  }

  // telegram:group:456:topic:7
  const topicMatch = key.match(/^(\w+):group:(\w+):topic:(\w+)$/);
  if (topicMatch) {
    return {
      channel: topicMatch[1],
      chatType: "group",
      chatId: topicMatch[2],
      topicId: topicMatch[3],
    };
  }

  // telegram:group:456
  const groupMatch = key.match(/^(\w+):group:(\w+)$/);
  if (groupMatch) {
    return { channel: groupMatch[1], chatType: "group", chatId: groupMatch[2] };
  }

  return null;
}

export function isHeartbeatSession(key: string): boolean {
  return key === HEARTBEAT_SESSION_KEY;
}
```

- [ ] **Step 4: Write failing config tests**

```ts
// tests/core/config.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { loadInstanceConfig, type InstanceConfig } from "@druzhok/core/config/config.js";

describe("loadInstanceConfig", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("loads defaults when no config file or env vars", () => {
    const config = loadInstanceConfig({ configPath: "/nonexistent.json" });
    expect(config.proxyUrl).toBe("");
    expect(config.proxyKey).toBe("");
    expect(config.telegramToken).toBe("");
  });

  it("loads from env vars", () => {
    process.env.DRUZHOK_PROXY_URL = "https://proxy.example.com";
    process.env.DRUZHOK_PROXY_KEY = "key_abc";
    process.env.DRUZHOK_TELEGRAM_TOKEN = "bot123:token";
    process.env.DRUZHOK_LOG_LEVEL = "debug";

    const config = loadInstanceConfig({ configPath: "/nonexistent.json" });
    expect(config.proxyUrl).toBe("https://proxy.example.com");
    expect(config.proxyKey).toBe("key_abc");
    expect(config.telegramToken).toBe("bot123:token");
    expect(config.logLevel).toBe("debug");
  });

  it("env vars override config file", () => {
    process.env.DRUZHOK_PROXY_URL = "https://override.com";

    const config = loadInstanceConfig({
      configPath: "/nonexistent.json",
      overrides: { proxyUrl: "https://fromfile.com" },
    });
    expect(config.proxyUrl).toBe("https://override.com");
  });
});
```

- [ ] **Step 5: Implement config.ts**

```ts
// packages/core/src/config/config.ts
import { readFileSync } from "node:fs";

export type ChatConfig = {
  systemPrompt?: string;
  model?: string;
};

export type InstanceConfig = {
  telegramToken: string;
  proxyUrl: string;
  proxyKey: string;
  logLevel: string;
  workspaceDir: string;
  defaultModel: string;
  chats: Record<string, ChatConfig>;
  heartbeat: {
    enabled: boolean;
    every: string;
    deliverTo: string;
    prompt?: string;
    ackMaxChars: number;
  };
  memory: {
    search: {
      enabled: boolean;
      model?: string;
    };
  };
};

type ConfigFileShape = Partial<{
  defaultModel: string;
  chats: Record<string, ChatConfig>;
  heartbeat: Partial<InstanceConfig["heartbeat"]>;
  memory: Partial<{
    search: Partial<InstanceConfig["memory"]["search"]>;
  }>;
  proxyUrl: string;
  proxyKey: string;
  logLevel: string;
  workspaceDir: string;
}>;

function loadConfigFile(path: string): ConfigFileShape {
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as ConfigFileShape;
  } catch {
    return {};
  }
}

export function loadInstanceConfig(opts?: {
  configPath?: string;
  overrides?: Partial<ConfigFileShape>;
}): InstanceConfig {
  const file = loadConfigFile(opts?.configPath ?? "druzhok.json");
  const merged = { ...file, ...opts?.overrides };

  return {
    telegramToken: process.env.DRUZHOK_TELEGRAM_TOKEN ?? "",
    proxyUrl: process.env.DRUZHOK_PROXY_URL ?? merged.proxyUrl ?? "",
    proxyKey: process.env.DRUZHOK_PROXY_KEY ?? merged.proxyKey ?? "",
    logLevel: process.env.DRUZHOK_LOG_LEVEL ?? merged.logLevel ?? "info",
    workspaceDir: process.env.DRUZHOK_WORKSPACE_DIR ?? merged.workspaceDir ?? "workspace",
    defaultModel: merged.defaultModel ?? "openai/gpt-4o",
    chats: merged.chats ?? {},
    heartbeat: {
      enabled: merged.heartbeat?.enabled ?? false,
      every: merged.heartbeat?.every ?? "30m",
      deliverTo: merged.heartbeat?.deliverTo ?? "",
      prompt: merged.heartbeat?.prompt,
      ackMaxChars: merged.heartbeat?.ackMaxChars ?? 300,
    },
    memory: {
      search: {
        enabled: merged.memory?.search?.enabled ?? true,
        model: merged.memory?.search?.model,
      },
    },
  };
}
```

- [ ] **Step 6: Create barrel exports**

```ts
// packages/core/src/index.ts
export * from "./config/config.js";
export * from "./session/session-key.js";
```

- [ ] **Step 7: Run all core tests**

Run: `cd druzhok-v2 && pnpm build && pnpm test -- tests/core/`
Expected: All PASS

- [ ] **Step 8: Run full test suite**

Run: `cd druzhok-v2 && pnpm build && pnpm test`
Expected: All tests across shared, proxy, core PASS

- [ ] **Step 9: Commit**

```bash
git add packages/core/ tests/core/
git commit -m "add core config and session key routing"
```

---

## Phase 1 Complete Checklist

After all tasks are done, verify:

- [ ] `pnpm build` succeeds with no errors
- [ ] `pnpm test` runs all tests and passes
- [ ] Proxy starts with `pnpm proxy` (will fail without env vars, but should not crash on missing config)
- [ ] All three packages (`shared`, `core`, `proxy`) resolve workspace dependencies correctly
