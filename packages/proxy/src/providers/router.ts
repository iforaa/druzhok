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

export type ResolveResult = { provider: ResolvedProvider; useFullModelId: boolean } | null;

export function resolveProviderWithHint(providerName: string, providers: ProxyConfig["providers"]): ResolveResult {
  if (providerName === "anthropic" && providers.anthropic) return { provider: { type: "anthropic", apiKey: providers.anthropic.apiKey, baseUrl: "https://api.anthropic.com" }, useFullModelId: false };
  if (providerName === "openai" && providers.openai) return { provider: { type: "openai-compat", apiKey: providers.openai.apiKey, baseUrl: "https://api.openai.com/v1/" }, useFullModelId: false };
  if (providerName === "nebius" && providers.nebius) return { provider: { type: "openai-compat", apiKey: providers.nebius.apiKey, baseUrl: providers.nebius.baseUrl }, useFullModelId: false };
  // Unknown provider prefix — fall through to default, keep full model ID
  if (providers.nebius) return { provider: { type: "openai-compat", apiKey: providers.nebius.apiKey, baseUrl: providers.nebius.baseUrl }, useFullModelId: true };
  if (providers.openai) return { provider: { type: "openai-compat", apiKey: providers.openai.apiKey, baseUrl: "https://api.openai.com/v1/" }, useFullModelId: true };
  if (providers.anthropic) return { provider: { type: "anthropic", apiKey: providers.anthropic.apiKey, baseUrl: "https://api.anthropic.com" }, useFullModelId: true };
  return null;
}

export function resolveProvider(providerName: string, providers: ProxyConfig["providers"]): ResolvedProvider | null {
  const result = resolveProviderWithHint(providerName, providers);
  return result?.provider ?? null;
}
