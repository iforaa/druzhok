import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createSessionStore } from "@druzhok/core/runtime/session-store.js";

describe("createSessionStore", () => {
  let sessionsDir: string;
  beforeEach(() => { sessionsDir = mkdtempSync(join(tmpdir(), "druzhok-sessions-")); });
  afterEach(() => { rmSync(sessionsDir, { recursive: true, force: true }); });

  it("creates new session for unknown key", () => {
    const store = createSessionStore(sessionsDir);
    const session = store.getOrCreate("telegram:dm:123");
    expect(session.sessionKey).toBe("telegram:dm:123");
    expect(session.sessionDir).toContain("telegram_dm_123");
  });
  it("returns same session for same key", () => {
    const store = createSessionStore(sessionsDir);
    const s1 = store.getOrCreate("telegram:dm:123");
    const s2 = store.getOrCreate("telegram:dm:123");
    expect(s1.sessionDir).toBe(s2.sessionDir);
  });
  it("creates different sessions for different keys", () => {
    const store = createSessionStore(sessionsDir);
    expect(store.getOrCreate("telegram:dm:123").sessionDir).not.toBe(store.getOrCreate("telegram:group:456").sessionDir);
  });
  it("deletes session", () => {
    const store = createSessionStore(sessionsDir);
    store.getOrCreate("telegram:dm:123");
    expect(store.has("telegram:dm:123")).toBe(true);
    store.delete("telegram:dm:123");
    expect(store.has("telegram:dm:123")).toBe(false);
  });
  it("lists active sessions", () => {
    const store = createSessionStore(sessionsDir);
    store.getOrCreate("telegram:dm:123");
    store.getOrCreate("telegram:group:456");
    expect(store.list()).toHaveLength(2);
  });
});
