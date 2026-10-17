import {AsyncLocalStorage} from 'node:async_hooks';

/**
 * Per-request MCP timing. Collects only durations and call counts; never inputs, user IDs, tokens or results.
 * authMs/dbMs are summed call durations; total_ms is wall-clock, so concurrent calls are not double counted.
 */
export type RequestMetrics = {
  startedAt: number;
  authMs: number;
  dbMs: number;
  calculationMs: number;
  authCalls: number;
  dbCalls: number;
};
export type TimingRecord = {
  tool: string;
  ok: boolean;
  error_code: string | null;
  total_ms: number;
  auth_ms: number;
  db_ms: number;
  calculation_ms: number;
  outbound_auth_calls: number;
  outbound_db_calls: number;
};

const store = new AsyncLocalStorage<RequestMetrics>();
const round = (ms: number) => Math.round(ms * 100) / 100;

export function classifyOutbound(url: string | URL): 'auth' | 'db' | null {
  let path: string;
  try {
    path = new URL(String(url)).pathname;
  } catch {
    return null;
  } // metrics must never break a request
  return path.startsWith('/auth/v1/') ? 'auth' : path.startsWith('/rest/v1/') ? 'db' : null;
}

export function runWithRequestMetrics<T>(fn: () => T): T {
  return store.run(
    {startedAt: performance.now(), authMs: 0, dbMs: 0, calculationMs: 0, authCalls: 0, dbCalls: 0},
    fn,
  );
}

export function currentRequestMetrics(): RequestMetrics | undefined {
  return store.getStore();
}

/** Wraps fetch for Supabase clients; outside a request context it is a plain pass-through. */
export function createMeteredFetch(base: typeof fetch): typeof fetch {
  return async (input, init) => {
    const metrics = store.getStore();
    const kind = metrics ? classifyOutbound(input instanceof Request ? input.url : input) : null;
    if (!metrics || !kind) return base(input, init);
    const started = performance.now();
    try {
      return await base(input, init);
    } finally {
      const elapsed = performance.now() - started;
      if (kind === 'auth') {
        metrics.authCalls++;
        metrics.authMs += elapsed;
      } else {
        metrics.dbCalls++;
        metrics.dbMs += elapsed;
      }
    }
  };
}

export function measureCalculation<T>(fn: () => T): T {
  const metrics = store.getStore();
  const started = performance.now();
  try {
    return fn();
  } finally {
    if (metrics) metrics.calculationMs += performance.now() - started;
  }
}

type ToolResult = {isError?: boolean; content?: {type: string; text?: string}[]};
export function timingRecord(
  tool: string,
  metrics: RequestMetrics,
  result: ToolResult,
  nowMs: number,
): TimingRecord {
  const text = result.isError ? result.content?.[0]?.text : undefined;
  return {
    tool,
    ok: !result.isError,
    error_code: result.isError ? (text && /^[A-Z_]{1,64}$/.test(text) ? text : 'UNKNOWN_ERROR') : null,
    total_ms: round(nowMs - metrics.startedAt),
    auth_ms: round(metrics.authMs),
    db_ms: round(metrics.dbMs),
    calculation_ms: round(metrics.calculationMs),
    outbound_auth_calls: metrics.authCalls,
    outbound_db_calls: metrics.dbCalls,
  };
}

/** Emits one compact FJ_MCP_TIMING line per tool call when MCP_TIMING_LOG=true. No DB writes. */
export function timedTool<A extends unknown[], R extends ToolResult>(
  tool: string,
  handler: (...args: A) => Promise<R>,
): (...args: A) => Promise<R> {
  return async (...args) => {
    const result = await handler(...args);
    const metrics = store.getStore();
    if (metrics && process.env.MCP_TIMING_LOG === 'true')
      console.info(`FJ_MCP_TIMING ${JSON.stringify(timingRecord(tool, metrics, result, performance.now()))}`);
    return result;
  };
}
