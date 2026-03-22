import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadInstanceConfig } from "@druzhok/core/config/config.js";

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
