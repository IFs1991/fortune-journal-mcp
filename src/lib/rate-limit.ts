import {sha256} from '@/src/domain/security';

/**
 * Best-effort, per-instance fixed-window limits (no Redis by design). They bound how much Supabase Auth and DB
 * work one address or one bearer can cause on a warm instance; the cross-instance control is the Vercel Firewall
 * rate-limit rule (docs/OPERATIONS.md). Business quotas live in the DB (fj_record_calculation), not here.
 */
export class FixedWindowLimiter {
  private buckets = new Map<string, {count: number; resetAt: number}>();
  private readonly limit: number;
  private readonly windowMs: number;
  private readonly maxKeys: number;
  constructor(limit: number, windowMs: number, maxKeys = 10_000) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.maxKeys = maxKeys;
  }

  /** Returns 0 when allowed, otherwise the seconds until the window resets. */
  take(key: string, now = Date.now()): number {
    let bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAt <= now) {
      if (this.buckets.size >= this.maxKeys) this.evict(now);
      bucket = {count: 0, resetAt: now + this.windowMs};
      this.buckets.set(key, bucket);
    }
    bucket.count += 1;
    return bucket.count > this.limit ? Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)) : 0;
  }

  private evict(now: number) {
    for (const [key, bucket] of this.buckets) if (bucket.resetAt <= now) this.buckets.delete(key);
    // Still full: drop the oldest windows (Map keeps insertion order) instead of growing without bound.
    for (const key of this.buckets.keys()) {
      if (this.buckets.size < this.maxKeys) break;
      this.buckets.delete(key);
    }
  }
}

/** Client address as set by Vercel's edge (x-real-ip / x-forwarded-for). Spoofable when not behind Vercel. */
export function clientAddress(request: Request): string {
  const forwarded = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim();
  return (request.headers.get('x-real-ip') ?? forwarded ?? 'unknown').slice(0, 64);
}

const LIMITS = {
  // MCP hosts call several tools per conversation turn; a single address may front many users (host egress).
  mcpAddress: new FixedWindowLimiter(600, 60_000),
  // One bearer token: each request costs one Supabase Auth getUser() call.
  mcpToken: new FixedWindowLimiter(120, 60_000),
  // Sign-in callback, consent decisions and account actions from a browser.
  web: new FixedWindowLimiter(120, 60_000),
};

export function rateLimitResponse(retryAfter: number): Response {
  return Response.json(
    {error: 'RATE_LIMITED'},
    {status: 429, headers: {'Retry-After': String(retryAfter), 'Cache-Control': 'no-store'}},
  );
}

/** null = allowed. */
export function limitWeb(request: Request): Response | null {
  const wait = LIMITS.web.take(clientAddress(request));
  return wait ? rateLimitResponse(wait) : null;
}

export function limitMcp(request: Request): Response | null {
  const wait = LIMITS.mcpAddress.take(clientAddress(request));
  if (wait) return rateLimitResponse(wait);
  const bearer = request.headers.get('authorization');
  const tokenWait = bearer ? LIMITS.mcpToken.take(sha256(bearer)) : 0;
  return tokenWait ? rateLimitResponse(tokenWait) : null;
}
