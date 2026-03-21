import { mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";

export type SessionEntry = { sessionKey: string; sessionDir: string; createdAt: number };
export type SessionStore = {
  getOrCreate(sessionKey: string): SessionEntry;
  has(sessionKey: string): boolean;
  delete(sessionKey: string): void;
  list(): SessionEntry[];
};

function sanitizeKey(key: string): string { return key.replace(/[^a-zA-Z0-9_-]/g, "_"); }

export function createSessionStore(baseDir: string): SessionStore {
  const sessions = new Map<string, SessionEntry>();
  mkdirSync(baseDir, { recursive: true });

  return {
    getOrCreate(sessionKey: string): SessionEntry {
      let entry = sessions.get(sessionKey);
      if (entry) return entry;
      const sessionDir = join(baseDir, sanitizeKey(sessionKey));
      mkdirSync(sessionDir, { recursive: true });
      entry = { sessionKey, sessionDir, createdAt: Date.now() };
      sessions.set(sessionKey, entry);
      return entry;
    },
    has(sessionKey: string): boolean { return sessions.has(sessionKey); },
    delete(sessionKey: string): void {
      const entry = sessions.get(sessionKey);
      if (entry) { if (existsSync(entry.sessionDir)) rmSync(entry.sessionDir, { recursive: true, force: true }); sessions.delete(sessionKey); }
    },
    list(): SessionEntry[] { return [...sessions.values()]; },
  };
}
