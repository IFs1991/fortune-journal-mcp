import {z} from 'zod';
import {adminSupabase} from '@/src/lib/supabase/server';

/** Run history and cost provenance for operator automation (automation_runs). */
type Actor = 'owner_agent' | 'server_cron';

/** Lease returned by fj_begin_run / fj_claim_publish. Parsed, so a malformed reply fails closed. */
const runLease = z.discriminatedUnion('acquired', [
  z.object({acquired: z.literal(true), runId: z.string().uuid(), attempt: z.number().int()}),
  // exhausted = no further attempt will ever be granted for this key: a failure, never "already done".
  z.object({
    acquired: z.literal(false),
    status: z.string(),
    exhausted: z.boolean().optional(),
    errorCode: z.string().nullable().optional(),
  }),
]);
export type RunLease = z.infer<typeof runLease>;
type ActiveRun = Extract<RunLease, {acquired: true}>;

export function parseRunLease(data: unknown): RunLease {
  const lease = runLease.safeParse(data);
  if (!lease.success) throw new Error('RUN_BACKEND_FAILURE');
  return lease.data;
}

/** Attempts per (task, key) granted by fj_begin_run; keep equal to the SQL. */
export const MAX_RUN_ATTEMPTS = 3;

/** A run attempt that failed; message is the stored error code, attempt tells whether another one will come. */
export class RunFailure extends Error {
  readonly attempt: number;
  constructor(code: string, attempt: number) {
    super(code);
    this.attempt = attempt;
  }
}

/** Our own errors carry UPPER_SNAKE codes; any other message (library, network text) is stored generically. */
export function safeErrorCode(error: unknown): string {
  return error instanceof Error && /^[A-Z][A-Z0-9_]{2,79}$/.test(error.message)
    ? error.message
    : 'OPERATION_FAILED';
}

async function beginRun(
  task: string,
  key: string,
  options: {postId?: string; actor?: Actor},
): Promise<RunLease> {
  const {data, error} = await adminSupabase().rpc('fj_begin_run', {
    p_task: task,
    p_key: key,
    p_actor: options.actor ?? 'owner_agent',
    p_post_id: options.postId ?? null,
  });
  if (error) throw new Error('RUN_BACKEND_FAILURE');
  return parseRunLease(data);
}

async function finishRun(run: ActiveRun, success: boolean, errorCode: string | null = null): Promise<void> {
  const {data, error} = await adminSupabase().rpc('fj_finish_run', {
    p_run_id: run.runId,
    p_attempt: run.attempt,
    p_success: success,
    p_error: errorCode,
  });
  if (error || data !== true) throw new Error('RUN_COMPLETION_FAILED');
}

/**
 * Runs `work` at most once per (task, key) under a lease and records success or the failure code.
 * A concurrent or repeated caller with the same key gets {acquired: false, status} instead.
 */
export async function runOnce<T>(
  task: string,
  key: string,
  options: {postId?: string; actor?: Actor},
  work: (run: ActiveRun) => Promise<T>,
): Promise<{acquired: true; value: T} | Extract<RunLease, {acquired: false}>> {
  const run = await beginRun(task, key, options);
  if (!run.acquired) return run;
  let value: T;
  try {
    value = await work(run);
  } catch (error) {
    const code = safeErrorCode(error);
    await finishRun(run, false, code);
    throw new RunFailure(code, run.attempt);
  }
  await finishRun(run, true);
  return {acquired: true, value};
}

type Cost = {
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  estimatedCost?: number;
  currency?: string;
};

function costColumns(cost: Cost) {
  if ((cost.estimatedCost === undefined) !== (cost.currency === undefined)) throw new Error('INVALID_COST');
  return {
    model: cost.model ?? null,
    input_tokens: cost.inputTokens ?? null,
    output_tokens: cost.outputTokens ?? null,
    estimated_cost: cost.estimatedCost ?? null,
    cost_currency: cost.currency ?? null,
    cost_source: 'external_reported',
  };
}

/** Attach an operator-reported (not provider-verified) cost to an existing run. */
export async function recordRunCost(runId: string, cost: Cost) {
  const {data, error} = await adminSupabase()
    .from('automation_runs')
    .update(costColumns(cost))
    .eq('id', runId)
    .select('id')
    .single();
  if (error || !data) throw new Error('RUN_NOT_FOUND');
  return {recorded: true, source: 'external_reported_not_provider_verified'};
}

export type ExternalRun = Cost & {
  task: 'weekly_analysis' | 'draft_post';
  startedAt: string;
  finishedAt: string;
  success: boolean;
  errorCode?: string;
};

/** Record a run that happened outside this server (e.g. the owner's agent). Idempotent per requestId. */
export async function recordExternalRun(requestId: string, input: ExternalRun) {
  const started = Date.parse(input.startedAt);
  const finished = Date.parse(input.finishedAt);
  const plausible =
    Number.isFinite(started) &&
    Number.isFinite(finished) &&
    finished >= started &&
    finished - started <= 86_400_000;
  if (!plausible || finished > Date.now() + 300_000) throw new Error('INVALID_RUN_PERIOD');
  if (input.success && input.errorCode) throw new Error('INVALID_RUN_STATUS');

  const row = {
    task: input.task,
    idempotency_key: `external:${requestId}`,
    status: input.success ? 'succeeded' : 'failed',
    actor_kind: 'external_report',
    started_at: new Date(started).toISOString(),
    finished_at: new Date(finished).toISOString(),
    lease_expires_at: new Date(finished).toISOString(),
    duration_ms: finished - started,
    error_code: input.errorCode ?? null,
    ...costColumns(input),
  };
  const db = adminSupabase();
  const {error} = await db
    .from('automation_runs')
    .upsert(row, {onConflict: 'task,idempotency_key', ignoreDuplicates: true});
  if (error) throw new Error('RUN_BACKEND_FAILURE');
  const {data: stored, error: lookupError} = await db
    .from('automation_runs')
    .select('*')
    .eq('task', row.task)
    .eq('idempotency_key', row.idempotency_key)
    .single();
  if (lookupError || !stored) throw new Error('RUN_BACKEND_FAILURE');
  // A reused requestId must describe the same run; PostgREST returns numerics/timestamps in its own format.
  for (const [column, expected] of Object.entries(row)) {
    if (!sameStoredValue(stored[column], expected)) throw new Error('IDEMPOTENCY_CONFLICT');
  }
  return {recorded: true, runId: stored.id, source: 'external_reported_not_provider_verified'};
}

function sameStoredValue(actual: unknown, expected: unknown): boolean {
  if (expected === null || actual === null) return actual === expected;
  if (typeof expected === 'number') return Number(actual) === expected;
  if (typeof expected === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(expected))
    return Date.parse(String(actual)) === Date.parse(expected);
  return actual === expected;
}
