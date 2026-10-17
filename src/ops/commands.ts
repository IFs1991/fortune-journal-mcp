import {z} from 'zod';
import {collectAccountMetrics, collectPostMetrics} from '@/src/ops/insights';
import {
  approvePost,
  draftPost,
  importPosts,
  publishPost,
  referralLink,
  resolvePublish,
} from '@/src/ops/posts';
import {report} from '@/src/ops/report';
import {recordExternalRun, recordRunCost} from '@/src/ops/runs';

/**
 * The complete operator API (/api/ops, HMAC-signed). Each command carries a requestId that doubles as its
 * idempotency key. Strict schemas reject unknown fields. Customers never reach this; see src/mcp/tools.ts.
 */
const uuid = z.string().uuid();
const label = z.string().regex(/^[A-Za-z0-9_.:-]{1,80}$/);
const timestamp = z.string().datetime();
const cost = {
  model: z.string().max(120).optional(),
  inputTokens: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),
  outputTokens: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),
  estimatedCost: z.number().nonnegative().max(1_000_000).optional(),
  currency: z
    .string()
    .regex(/^[A-Z]{3}$/)
    .optional(),
};
const ZODIAC = [
  'aries',
  'taurus',
  'gemini',
  'cancer',
  'leo',
  'virgo',
  'libra',
  'scorpio',
  'sagittarius',
  'capricorn',
  'aquarius',
  'pisces',
] as const;

const command = <A extends string, S extends z.ZodRawShape>(action: A, shape: S) =>
  z.object({requestId: uuid, action: z.literal(action), ...shape}).strict();

export const opsCommand = z.discriminatedUnion('action', [
  command('draft_post', {
    // Threads text posts allow 500 characters (code points, not UTF-16 units).
    body: z
      .string()
      .min(1)
      .refine((text) => [...text].length <= 500),
    topic: z.enum(['love', 'work', 'money', 'general']),
    method: z.enum(['tarot', 'numerology', 'mixed']),
    tone: z.enum(['empathetic', 'assertive', 'question']),
    language: z.string().regex(/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$/),
    hookText: z.string().max(240).optional(),
    ctaKey: z.enum(['none', 'reflect', 'save', 'reply', 'visit_profile']),
    promptVersion: label,
    experimentId: label.optional(),
    variantKey: label.optional(),
    scheduledAt: timestamp.optional(),
    zodiac: z.enum(ZODIAC).optional(),
  }),
  command('approve_post', {postId: uuid, bodySha256: z.string().regex(/^[a-f0-9]{64}$/)}),
  command('publish_post', {postId: uuid}),
  // After a person checked the Threads profile for a publish_unknown post.
  command('resolve_publish', {
    postId: uuid,
    outcome: z.enum(['published', 'not_published']),
    externalPostId: z
      .string()
      .regex(/^\d{1,80}$/)
      .optional(),
  }).refine((input) => (input.outcome === 'published') === (input.externalPostId !== undefined), {
    message: 'externalPostId is required exactly when outcome is published',
  }),
  command('collect_post_metrics', {postId: uuid, kind: z.enum(['manual', 'backfill_now']).default('manual')}),
  command('collect_account_metrics', {since: timestamp, until: timestamp}),
  command('import_posts', {after: z.string().max(2048).optional()}),
  command('report', {from: timestamp, until: timestamp}),
  command('referral_link', {postId: uuid}),
  command('record_external_run', {
    task: z.enum(['weekly_analysis', 'draft_post']),
    startedAt: timestamp,
    finishedAt: timestamp,
    success: z.boolean(),
    errorCode: z
      .string()
      .regex(/^[A-Z0-9_]{1,80}$/)
      .optional(),
    ...cost,
  }),
  command('record_run_cost', {runId: uuid, ...cost}),
]);
export type OpsCommand = z.infer<typeof opsCommand>;

export function runCommand(input: OpsCommand): Promise<unknown> {
  switch (input.action) {
    case 'draft_post':
      return draftPost(input.requestId, input);
    case 'approve_post':
      return approvePost(input.postId, input.bodySha256);
    case 'publish_post':
      return publishPost(input.postId);
    case 'resolve_publish':
      return resolvePublish(input.postId, input.externalPostId ?? null);
    case 'collect_post_metrics':
      return collectPostMetrics(input.postId, input.requestId, {kind: input.kind});
    case 'collect_account_metrics':
      return collectAccountMetrics(input.requestId, input.since, input.until);
    case 'import_posts':
      return importPosts(input.requestId, input.after);
    case 'report':
      return report(input.from, input.until);
    case 'referral_link':
      return referralLink(input.postId);
    case 'record_external_run':
      return recordExternalRun(input.requestId, input);
    case 'record_run_cost':
      return recordRunCost(input.runId, input);
  }
}

/** Error codes an operator may see; anything else is reported as OPERATION_FAILED. */
const PUBLIC_ERRORS = new Set([
  'PUBLISH_DISABLED',
  'INSIGHTS_DISABLED',
  'THREADS_NOT_CONFIGURED',
  'POST_NOT_APPROVED',
  'IDEMPOTENCY_CONFLICT',
  'THREADS_RATE_LIMITED',
  'THREADS_PERMISSION_DENIED',
  'POST_NOT_FOUND',
  'POST_NOT_UNKNOWN',
  'EXTERNAL_ID_CONFLICT',
]);
export function publicErrorCode(error: unknown): string {
  return error instanceof Error && PUBLIC_ERRORS.has(error.message) ? error.message : 'OPERATION_FAILED';
}
