# Druzhok v2 Phase 6: Docker + Integration Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create Dockerfiles for both instance and proxy, a workspace template for new instances, and wire all existing packages into a runnable entry point.

**Architecture:** Two Docker images: `druzhok-instance` (runs Telegram bot + pi-agent-core + memory) and `druzhok-proxy` (runs the LLM proxy). The instance entry point wires core runtime, telegram channel, memory, heartbeat, and skills into a single process.

**Tech Stack:** Docker, `@druzhok/shared`, `@druzhok/core`, `@druzhok/telegram`, `@druzhok/proxy`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md` — sections "System Topology", "Graceful Shutdown", "Project Structure"

---

## File Structure

```
druzhok-v2/
├── docker/
│   ├── Dockerfile.instance       # Per-user instance image
│   └── Dockerfile.proxy          # Proxy server image
├── workspace-template/
│   ├── AGENTS.md                 # Default agent personality
│   ├── HEARTBEAT.md              # Empty heartbeat file
│   └── memory/                   # Empty memory directory
│       └── .gitkeep
├── packages/core/src/
│   └── instance.ts               # Instance entry point: wires everything
```

---

### Task 1: Workspace Template

**Files:**
- Create: `workspace-template/AGENTS.md`
- Create: `workspace-template/HEARTBEAT.md`
- Create: `workspace-template/memory/.gitkeep`

- [ ] **Step 1: Create AGENTS.md**

```markdown
# Druzhok

You are Druzhok, a personal AI assistant. You communicate via Telegram.

## Personality

- Helpful, concise, and friendly
- Answer in the same language the user writes in
- Use markdown formatting for code and structured content

## Memory

- Write durable facts (preferences, decisions, reference info) to MEMORY.md
- Write daily notes and ephemeral context to memory/YYYY-MM-DD.md
- When someone says "remember this," write it down immediately

## Tools

You have access to shell commands, file operations, memory search, and can send proactive messages. Use tools when they help accomplish the user's request.
```

- [ ] **Step 2: Create HEARTBEAT.md**

```markdown
# Heartbeat Tasks

<!-- Add tasks here for the bot to check periodically -->
<!-- Example: - Check ~/projects/myapp for build failures -->
```

- [ ] **Step 3: Create memory/.gitkeep**

Empty file to preserve directory structure.

- [ ] **Step 4: Commit**

```bash
git commit -m "add workspace template for new instances"
```

---

### Task 2: Dockerfiles

**Files:**
- Create: `docker/Dockerfile.proxy`
- Create: `docker/Dockerfile.instance`

- [ ] **Step 1: Create Dockerfile.proxy**

```dockerfile
FROM node:22-slim AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY packages/shared/package.json packages/shared/
COPY packages/proxy/package.json packages/proxy/
COPY packages/core/package.json packages/core/
RUN pnpm install --frozen-lockfile
COPY tsconfig.json tsconfig.build.json ./
COPY packages/shared/ packages/shared/
COPY packages/proxy/ packages/proxy/
COPY packages/core/ packages/core/
RUN pnpm build

FROM node:22-slim
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY --from=builder /app/package.json /app/pnpm-workspace.yaml /app/pnpm-lock.yaml ./
COPY --from=builder /app/packages/shared/package.json packages/shared/
COPY --from=builder /app/packages/proxy/package.json packages/proxy/
COPY --from=builder /app/packages/core/package.json packages/core/
RUN pnpm install --frozen-lockfile --prod
COPY --from=builder /app/packages/shared/dist packages/shared/dist
COPY --from=builder /app/packages/proxy/dist packages/proxy/dist
COPY --from=builder /app/packages/core/dist packages/core/dist

EXPOSE 8080
ENV NODE_ENV=production
CMD ["node", "packages/proxy/dist/index.js"]
```

- [ ] **Step 2: Create Dockerfile.instance**

```dockerfile
FROM node:22-slim AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY packages/shared/package.json packages/shared/
COPY packages/core/package.json packages/core/
COPY packages/telegram/package.json packages/telegram/
RUN pnpm install --frozen-lockfile
COPY tsconfig.json tsconfig.build.json ./
COPY packages/shared/ packages/shared/
COPY packages/core/ packages/core/
COPY packages/telegram/ packages/telegram/
RUN pnpm build

FROM node:22-slim
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY --from=builder /app/package.json /app/pnpm-workspace.yaml /app/pnpm-lock.yaml ./
COPY --from=builder /app/packages/shared/package.json packages/shared/
COPY --from=builder /app/packages/core/package.json packages/core/
COPY --from=builder /app/packages/telegram/package.json packages/telegram/
RUN pnpm install --frozen-lockfile --prod
COPY --from=builder /app/packages/shared/dist packages/shared/dist
COPY --from=builder /app/packages/core/dist packages/core/dist
COPY --from=builder /app/packages/telegram/dist packages/telegram/dist
COPY workspace-template/ /app/workspace-template/

ENV NODE_ENV=production
ENV DRUZHOK_WORKSPACE_DIR=/data/workspace
VOLUME ["/data"]
CMD ["node", "packages/core/dist/instance.js"]
```

- [ ] **Step 3: Commit**

```bash
git commit -m "add Dockerfiles for proxy and instance"
```

---

### Task 3: Instance Entry Point

**Files:**
- Create: `packages/core/src/instance.ts`

This is the main wiring file that starts an instance. It connects config, telegram, memory, heartbeat, skills, and reply pipeline. For now it's a skeleton that validates config and starts the Telegram bot — the pi-agent-core integration will come when that library's API surface is explored in a future phase.

- [ ] **Step 1: Implement instance.ts**

```ts
// packages/core/src/instance.ts
import { loadInstanceConfig } from "./config/config.js";
import { parseInterval } from "./heartbeat/parse-interval.js";
import { createHeartbeatManager } from "./heartbeat/heartbeat.js";
import { createSkillRegistry } from "./skills/registry.js";
import { readMemoryFile, todayLogPath, yesterdayLogPath, listMemoryFiles } from "./memory/files.js";
import { isHeartbeatMdEmpty } from "./memory/flush.js";
import { join } from "node:path";
import { existsSync, mkdirSync, cpSync } from "node:fs";

export async function startInstance(): Promise<{ stop: () => Promise<void> }> {
  const config = loadInstanceConfig();

  // Validate required config
  if (!config.telegramToken) {
    console.error("DRUZHOK_TELEGRAM_TOKEN is required");
    process.exit(1);
  }
  if (!config.proxyUrl) {
    console.error("DRUZHOK_PROXY_URL is required");
    process.exit(1);
  }

  // Initialize workspace from template if needed
  const workspace = config.workspaceDir;
  if (!existsSync(workspace)) {
    const templateDir = join(import.meta.dirname ?? ".", "..", "..", "..", "workspace-template");
    if (existsSync(templateDir)) {
      cpSync(templateDir, workspace, { recursive: true });
      console.log(`Initialized workspace from template at ${workspace}`);
    } else {
      mkdirSync(workspace, { recursive: true });
      mkdirSync(join(workspace, "memory"), { recursive: true });
      console.log(`Created empty workspace at ${workspace}`);
    }
  }

  // Load skills
  const skillsDir = join(workspace, "skills");
  const skills = createSkillRegistry(skillsDir);
  console.log(`Loaded ${skills.list().length} skills`);

  // Setup heartbeat
  let heartbeat: ReturnType<typeof createHeartbeatManager> | null = null;
  if (config.heartbeat.enabled) {
    const intervalMs = parseInterval(config.heartbeat.every);
    if (intervalMs) {
      heartbeat = createHeartbeatManager({
        intervalMs,
        readHeartbeatMd: () => readMemoryFile(join(workspace, "HEARTBEAT.md")),
        onTick: async () => {
          console.log("Heartbeat tick — agent run would execute here");
          // TODO: Wire to pi-agent-core run with heartbeat prompt
        },
      });
      heartbeat.start();
      console.log(`Heartbeat started (every ${config.heartbeat.every})`);
    }
  }

  console.log("Druzhok instance started");
  console.log(`  Workspace: ${workspace}`);
  console.log(`  Proxy: ${config.proxyUrl}`);
  console.log(`  Model: ${config.defaultModel}`);

  // Graceful shutdown
  const stop = async () => {
    console.log("Shutting down...");
    heartbeat?.stop();
    // TODO: Stop telegram bot, wait for in-progress runs, flush memory
    console.log("Shutdown complete");
  };

  // Handle SIGTERM (Docker stop)
  process.on("SIGTERM", () => {
    void stop().then(() => process.exit(0));
  });

  process.on("SIGINT", () => {
    void stop().then(() => process.exit(0));
  });

  return { stop };
}

// Run if executed directly
const isMain = process.argv[1]?.endsWith("instance.js") || process.argv[1]?.endsWith("instance.ts");
if (isMain) {
  startInstance().catch((err) => {
    console.error("Failed to start instance:", err);
    process.exit(1);
  });
}
```

- [ ] **Step 2: Build**

Run: `pnpm build`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git commit -m "add instance entry point with config, heartbeat, skills wiring"
```

---

### Task 4: Docker Compose Example

**Files:**
- Create: `docker/docker-compose.example.yml`

- [ ] **Step 1: Create docker-compose.example.yml**

```yaml
# Example docker-compose for running Druzhok
# Copy to docker-compose.yml and fill in your values

services:
  proxy:
    build:
      context: ..
      dockerfile: docker/Dockerfile.proxy
    ports:
      - "8080:8080"
    environment:
      - ANTHROPIC_API_KEY=sk-ant-your-key
      - OPENAI_API_KEY=sk-your-key
      - NEBIUS_API_KEY=your-nebius-key
      - NEBIUS_BASE_URL=https://api.studio.nebius.com/v1/
      - DRUZHOK_PROXY_PORT=8080
      - DRUZHOK_PROXY_REGISTRY_PATH=/etc/druzhok/instances.json
    volumes:
      - ./instances.json:/etc/druzhok/instances.json:ro
    restart: unless-stopped

  instance:
    build:
      context: ..
      dockerfile: docker/Dockerfile.instance
    environment:
      - DRUZHOK_TELEGRAM_TOKEN=your-bot-token
      - DRUZHOK_PROXY_URL=http://proxy:8080
      - DRUZHOK_PROXY_KEY=your-instance-key
      - DRUZHOK_WORKSPACE_DIR=/data/workspace
    volumes:
      - instance-data:/data
    depends_on:
      - proxy
    restart: unless-stopped

volumes:
  instance-data:
```

- [ ] **Step 2: Commit**

```bash
git commit -m "add docker-compose example"
```

---

## Phase 6 Complete Checklist

- [ ] Workspace template has AGENTS.md, HEARTBEAT.md, memory/ directory
- [ ] Dockerfile.proxy builds and starts the proxy server
- [ ] Dockerfile.instance builds and starts the instance
- [ ] Instance entry point validates config, initializes workspace, loads skills, starts heartbeat
- [ ] Graceful shutdown handles SIGTERM/SIGINT
- [ ] docker-compose.example.yml shows full setup
- [ ] `pnpm build` succeeds across all packages
- [ ] `pnpm test` all pass
