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
