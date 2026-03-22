import { describe, it, expect } from "vitest";
import { parseModelId, resolveProvider } from "@druzhok/proxy/providers/router.js";

describe("parseModelId", () => {
  it("parses anthropic/claude-sonnet-4-20250514", () => {
    expect(parseModelId("anthropic/claude-sonnet-4-20250514")).toEqual({
      provider: "anthropic", model: "claude-sonnet-4-20250514",
    });
  });
  it("parses nebius/deepseek-r1", () => {
    expect(parseModelId("nebius/deepseek-r1")).toEqual({
      provider: "nebius", model: "deepseek-r1",
    });
  });
  it("parses openai/gpt-4o", () => {
    expect(parseModelId("openai/gpt-4o")).toEqual({
      provider: "openai", model: "gpt-4o",
    });
  });
  it("treats unprefixed model as default provider", () => {
    expect(parseModelId("gpt-4o")).toEqual({
      provider: "default", model: "gpt-4o",
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
    expect(result).toEqual({ type: "anthropic", apiKey: "sk-ant-test", baseUrl: "https://api.anthropic.com" });
  });
  it("resolves nebius as openai-compat", () => {
    const result = resolveProvider("nebius", providers);
    expect(result).toEqual({ type: "openai-compat", apiKey: "nb-test", baseUrl: "https://api.nebius.com/v1/" });
  });
  it("resolves openai as openai-compat", () => {
    const result = resolveProvider("openai", providers);
    expect(result).toEqual({ type: "openai-compat", apiKey: "sk-test", baseUrl: "https://api.openai.com/v1/" });
  });
  it("falls through unknown provider to default (nebius)", () => {
    const result = resolveProvider("google", providers);
    expect(result).not.toBeNull();
    expect(result?.type).toBe("openai-compat");
  });
  it("resolves default to first configured provider", () => {
    const result = resolveProvider("default", providers);
    expect(result).not.toBeNull();
  });
});
