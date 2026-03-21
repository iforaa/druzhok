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
