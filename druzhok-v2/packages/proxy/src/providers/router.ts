import type { ProxyConfig } from "../config.js";

export type ParsedModelId = { provider: string; model: string };

export function parseModelId(modelId: string): ParsedModelId {
  const slashIndex = modelId.indexOf("/");
  if (slashIndex === -1) return { provider: "default", model: modelId };
  return { provider: modelId.slice(0, slashIndex), model: modelId.slice(slashIndex + 1) };
}

export type ResolvedProvider =
  | { type: "anthropic"; apiKey: string; baseUrl: string }
  | { type: "openai-compat"; apiKey: string; baseUrl: string };

export function resolveProvider(providerName: string, providers: ProxyConfig["providers"]): ResolvedProvider | null {
  if (providerName === "anthropic" && providers.anthropic) return { type: "anthropic", apiKey: providers.anthropic.apiKey, baseUrl: "https://api.anthropic.com" };
  if (providerName === "openai" && providers.openai) return { type: "openai-compat", apiKey: providers.openai.apiKey, baseUrl: "https://api.openai.com/v1/" };
  if (providerName === "nebius" && providers.nebius) return { type: "openai-compat", apiKey: providers.nebius.apiKey, baseUrl: providers.nebius.baseUrl };
  if (providerName === "default") {
    if (providers.openai) return resolveProvider("openai", providers);
    if (providers.anthropic) return resolveProvider("anthropic", providers);
    if (providers.nebius) return resolveProvider("nebius", providers);
  }
  return null;
}
