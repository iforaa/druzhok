import { describe, it, expect, vi, beforeEach } from "vitest";
import { createRateLimiter, type RateLimitTiers } from "@druzhok/proxy/rate-limit.js";

const tiers: RateLimitTiers = {
  default: { requestsPerMinute: 60 },
  limited: { requestsPerMinute: 3 },
};

describe("createRateLimiter", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  it("allows requests under the limit", () => {
    const limiter = createRateLimiter(tiers);
    const result = limiter.check("key1", "default");
    expect(result).toEqual({ allowed: true });
  });

  it("blocks requests over the limit", () => {
    const limiter = createRateLimiter(tiers);
    for (let i = 0; i < 3; i++) {
      limiter.check("key1", "limited");
    }
    const result = limiter.check("key1", "limited");
    expect(result.allowed).toBe(false);
    expect(result.retryAfter).toBeGreaterThan(0);
  });

  it("resets after window expires", () => {
    const limiter = createRateLimiter(tiers);
    for (let i = 0; i < 3; i++) {
      limiter.check("key1", "limited");
    }
    expect(limiter.check("key1", "limited").allowed).toBe(false);

    vi.advanceTimersByTime(60_000);

    expect(limiter.check("key1", "limited").allowed).toBe(true);
  });

  it("tracks keys independently", () => {
    const limiter = createRateLimiter(tiers);
    for (let i = 0; i < 3; i++) {
      limiter.check("key1", "limited");
    }
    expect(limiter.check("key1", "limited").allowed).toBe(false);
    expect(limiter.check("key2", "limited").allowed).toBe(true);
  });

  it("falls back to default tier for unknown tier", () => {
    const limiter = createRateLimiter(tiers);
    const result = limiter.check("key1", "unknown_tier");
    expect(result.allowed).toBe(true);
  });
});
