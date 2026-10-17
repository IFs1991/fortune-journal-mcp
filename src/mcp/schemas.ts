import {z} from 'zod';

/**
 * Input and output schemas of the 7 customer MCP tools. tools/list advertises them and the SDK validates
 * arguments and structuredContent against them, so they are the wire contract: change them additively.
 */
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const topic = z.enum(['love', 'work', 'money', 'general']);
const tier = z.enum(['free', 'trial', 'premium']);
const receipt = {
  readingId: z.string().uuid(),
  tier,
  remainingAtCompletion: z.number().int().nonnegative(),
  replayed: z.boolean(),
};

export const noInput = z.object({});

export const accountProfileOutput = z.object({id: z.string(), name: z.string()});
export const accessStatusOutput = z.object({tier: z.enum(['free', 'trial', 'premium', 'suspended'])});

export const journalSchemaOutput = z.object({
  schemaVersion: z.string(),
  sheets: z.array(z.object({name: z.string(), headers: z.array(z.string())})),
  ownership: z.literal('user_google_drive'),
  instructions: z.string(),
  writeRules: z.array(z.string()),
});

export const numerologyInput = z.object({
  requestId: z
    .string()
    .uuid()
    .optional()
    .describe(
      'Reuse this operation ID with identical inputs for a retry. A new ID requests a new calculation.',
    ),
  topic: topic
    .optional()
    .describe('User-chosen category only. Stored only if separately opted in; never infer private concerns.'),
  birthDate: isoDate.describe('ISO date YYYY-MM-DD. User may choose not to share.'),
  asOf: isoDate.optional().describe('Calendar date to calculate the personal cycle, default today UTC.'),
});
export const numerologyOutput = z.object({
  schemaVersion: z.literal('1.0'),
  algorithm: z.string(),
  birthDate: z.string(),
  asOf: z.string(),
  lifePath: z.number().int(),
  personalYear: z.number().int(),
  personalMonth: z.number().int(),
  interpretationKeys: z.array(z.string()),
  disclaimer: z.string(),
  requestId: z.string().uuid(),
  ...receipt,
});

export const tarotInput = z.object({
  topic: topic.optional(),
  count: z.union([z.literal(1), z.literal(3)]).default(1),
  drawId: z
    .string()
    .uuid()
    .optional()
    .describe(
      'Reuse for the same draw and count to avoid a second quota charge. Keep this ID in your own journal.',
    ),
});
export const tarotOutput = z.object({
  schemaVersion: z.literal('1.0'),
  algorithm: z.string(),
  drawId: z.string().uuid(),
  cards: z.array(
    z.object({index: z.number().int(), name: z.string(), orientation: z.enum(['upright', 'reversed'])}),
  ),
  disclaimer: z.string(),
  ...receipt,
});

export const feedbackInput = z.object({
  readingId: z.string().uuid(),
  usefulness: z.number().int().min(1).max(5),
  matchAssessment: z.enum(['not_assessed', 'matched', 'mixed', 'not_matched', 'unclear']),
  followupDate: isoDate.optional(),
  explicitUserRequest: z.literal(true),
});
export const feedbackOutput = z.object({saved: z.boolean(), assessment: z.literal('self_reported')});

export const journalActionInput = z.object({
  requestId: z.string().uuid(),
  action: z.enum(['journal_save_reported', 'life_log_reported', 'review_reported']),
  readingId: z.string().uuid().optional(),
  explicitUserRequest: z.literal(true),
});
export const journalActionOutput = z.object({
  recorded: z.boolean(),
  verification: z.literal('self_reported_not_independently_verified'),
});

/** Result of fj_record_calculation (supabase/migrations): parsed, never cast, so a contract drift fails closed. */
export const calculationOutcome = z.discriminatedUnion('ok', [
  z.object({ok: z.literal(true), ...receipt}),
  z.object({
    ok: z.literal(false),
    reason: z.enum([
      'ACCOUNT_SUSPENDED',
      'FEATURE_NOT_INCLUDED',
      'IDEMPOTENCY_CONFLICT',
      'USAGE_LIMIT_REACHED',
    ]),
  }),
]);
