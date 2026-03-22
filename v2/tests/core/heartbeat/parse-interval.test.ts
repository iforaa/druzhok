import { describe, it, expect } from "vitest";
import { parseInterval } from "@druzhok/core/heartbeat/parse-interval.js";

describe("parseInterval", () => {
  it("parses minutes", () => { expect(parseInterval("30m")).toBe(30 * 60 * 1000); });
  it("parses hours", () => { expect(parseInterval("1h")).toBe(60 * 60 * 1000); });
  it("parses seconds", () => { expect(parseInterval("45s")).toBe(45 * 1000); });
  it("parses combined h+m", () => { expect(parseInterval("1h30m")).toBe(90 * 60 * 1000); });
  it("returns null for invalid", () => { expect(parseInterval("foo")).toBeNull(); });
  it("returns null for empty", () => { expect(parseInterval("")).toBeNull(); });
});
