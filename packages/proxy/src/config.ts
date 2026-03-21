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
            baseUrl: process.env.NEBIUS_BASE_URL ?? "https://api.studio.nebius.com/v1/",
          }
        : undefined,
    },
    registryPath: process.env.DRUZHOK_PROXY_REGISTRY_PATH ?? "/etc/druzhok/instances.json",
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
