import {randomUUID} from 'node:crypto';
import type {z} from 'zod';
import {calculateNumerology, parseISODate} from '@/src/domain/numerology';
import {requestFingerprint, sha256} from '@/src/domain/security';
import {drawTarot} from '@/src/domain/tarot';
import {clientPlatform, isEnabled} from '@/src/lib/env';
import {secret} from '@/src/lib/secrets';
import {measureCalculation} from '@/src/lib/perf';
import {adminSupabase} from '@/src/lib/supabase/server';
import {result, toolError} from '@/src/mcp/response';
import {calculationOutcome, type numerologyInput, type tarotInput} from '@/src/mcp/schemas';
import type {ToolContext} from '@/src/mcp/tools';

type Feature = 'calculate_numerology' | 'draw_tarot';

const todayUtc = () => new Date().toISOString().slice(0, 10);

/**
 * The single DB round trip of a reading: access check, trial start, idempotent replay, usage limit and the
 * ledger row commit together in fj_record_calculation. Only an HMAC fingerprint of the input is sent.
 */
async function recordCalculation(
  context: ToolContext,
  calculation: {
    requestId: string;
    feature: Feature;
    algorithm: string;
    targetDate: string;
    input: unknown[];
    topic?: string;
  },
) {
  const analytics = isEnabled('PRODUCT_ANALYTICS_ENABLED');
  const {data, error} = await adminSupabase().rpc('fj_record_calculation', {
    p_user_id: context.userId,
    p_request_id: calculation.requestId,
    p_fingerprint: requestFingerprint(
      secret('REQUEST_HMAC_KEY'),
      context.userId,
      calculation.requestId,
      calculation.feature,
      calculation.input,
    ),
    p_feature: calculation.feature,
    p_algorithm: calculation.algorithm,
    p_target_date: calculation.targetDate,
    p_topic: analytics ? (calculation.topic ?? null) : null,
    p_client: clientPlatform(context.clientId),
    p_collect_analytics: analytics,
  });
  const outcome = calculationOutcome.safeParse(data);
  if (error || !outcome.success) throw new Error('USAGE_BACKEND_FAILURE');
  return outcome.data;
}

type Receipt = Extract<z.infer<typeof calculationOutcome>, {ok: true}>;
const receiptOf = ({readingId, tier, remainingAtCompletion, replayed}: Receipt) => ({
  readingId,
  tier,
  remainingAtCompletion,
  replayed,
});

export async function calculateNumerologyTool(args: z.infer<typeof numerologyInput>, context: ToolContext) {
  const asOf = args.asOf ?? todayUtc();
  try {
    parseISODate(args.birthDate);
    parseISODate(asOf);
  } catch {
    return toolError('INVALID_DATE');
  }
  const requestId = args.requestId ?? randomUUID();
  const reading = measureCalculation(() => calculateNumerology(args.birthDate, asOf));
  const outcome = await recordCalculation(context, {
    requestId,
    feature: 'calculate_numerology',
    algorithm: reading.algorithm,
    targetDate: asOf,
    input: [reading.algorithm, args.birthDate, asOf],
    topic: args.topic,
  });
  if (!outcome.ok) return toolError(outcome.reason);
  return result({...reading, requestId, ...receiptOf(outcome)});
}

export async function drawTarotTool(args: z.infer<typeof tarotInput>, context: ToolContext) {
  let tarotKey: string;
  try {
    tarotKey = secret('TAROT_HMAC_KEY');
  } catch {
    return toolError('SERVICE_NOT_CONFIGURED');
  }
  const drawId = args.drawId ?? randomUUID();
  const reading = measureCalculation(() => drawTarot(context.userId, tarotKey, args.count, drawId));
  // The ledger replays an identical drawId on any later day, so today's date is only the draw's record date.
  const outcome = await recordCalculation(context, {
    requestId: drawId,
    feature: 'draw_tarot',
    algorithm: reading.algorithm,
    targetDate: todayUtc(),
    input: [reading.algorithm, args.count, process.env.TAROT_KEY_VERSION ?? 'v1', sha256(tarotKey)],
    topic: args.topic,
  });
  if (!outcome.ok) return toolError(outcome.reason);
  return result({...reading, ...receiptOf(outcome)});
}
