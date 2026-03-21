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
  memory: Partial<{ search: Partial<InstanceConfig["memory"]["search"]> }>;
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
