export type TierConfig = {
  requestsPerMinute: number;
};

export type RateLimitTiers = Record<string, TierConfig>;

export type RateLimitResult =
  | { allowed: true }
  | { allowed: false; retryAfter: number };

type Bucket = {
  count: number;
  windowStart: number;
};

export type RateLimiter = {
  check(key: string, tier: string): RateLimitResult;
};

export function createRateLimiter(tiers: RateLimitTiers): RateLimiter {
  const buckets = new Map<string, Bucket>();
  const WINDOW_MS = 60_000;

  return {
    check(key: string, tier: string): RateLimitResult {
      const tierConfig = tiers[tier] ?? tiers["default"];
      if (!tierConfig) {
        return { allowed: true };
      }

      const now = Date.now();
      let bucket = buckets.get(key);

      if (!bucket || now - bucket.windowStart >= WINDOW_MS) {
        bucket = { count: 0, windowStart: now };
        buckets.set(key, bucket);
      }

      if (bucket.count >= tierConfig.requestsPerMinute) {
        const retryAfter = Math.ceil(
          (bucket.windowStart + WINDOW_MS - now) / 1000
        );
        return { allowed: false, retryAfter: Math.max(1, retryAfter) };
      }

      bucket.count++;
      return { allowed: true };
    },
  };
}
