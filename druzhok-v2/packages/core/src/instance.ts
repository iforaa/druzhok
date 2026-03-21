import { loadInstanceConfig } from "./config/config.js";
import { parseInterval } from "./heartbeat/parse-interval.js";
import { createHeartbeatManager } from "./heartbeat/heartbeat.js";
import { createSkillRegistry } from "./skills/registry.js";
import { readMemoryFile } from "./memory/files.js";
import { join } from "node:path";
import { existsSync, mkdirSync, cpSync } from "node:fs";

export async function startInstance(): Promise<{ stop: () => Promise<void> }> {
  const config = loadInstanceConfig();

  if (!config.telegramToken) { console.error("DRUZHOK_TELEGRAM_TOKEN is required"); process.exit(1); }
  if (!config.proxyUrl) { console.error("DRUZHOK_PROXY_URL is required"); process.exit(1); }

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

  const skillsDir = join(workspace, "skills");
  const skills = createSkillRegistry(skillsDir);
  console.log(`Loaded ${skills.list().length} skills`);

  let heartbeat: ReturnType<typeof createHeartbeatManager> | null = null;
  if (config.heartbeat.enabled) {
    const intervalMs = parseInterval(config.heartbeat.every);
    if (intervalMs) {
      heartbeat = createHeartbeatManager({
        intervalMs,
        readHeartbeatMd: () => readMemoryFile(join(workspace, "HEARTBEAT.md")),
        onTick: async () => { console.log("Heartbeat tick — agent run would execute here"); },
      });
      heartbeat.start();
      console.log(`Heartbeat started (every ${config.heartbeat.every})`);
    }
  }

  console.log("Druzhok instance started");
  console.log(`  Workspace: ${workspace}`);
  console.log(`  Proxy: ${config.proxyUrl}`);
  console.log(`  Model: ${config.defaultModel}`);

  const stop = async () => {
    console.log("Shutting down...");
    heartbeat?.stop();
    console.log("Shutdown complete");
  };

  process.on("SIGTERM", () => { void stop().then(() => process.exit(0)); });
  process.on("SIGINT", () => { void stop().then(() => process.exit(0)); });

  return { stop };
}

const isMain = process.argv[1]?.endsWith("instance.js") || process.argv[1]?.endsWith("instance.ts");
if (isMain) {
  startInstance().catch((err) => { console.error("Failed to start instance:", err); process.exit(1); });
}
