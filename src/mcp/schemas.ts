import { z } from 'zod';

/** Output schemas advertised in tools/list; the SDK validates structuredContent against them. */
const tier = z.enum(['free','trial','premium']);
const receipt = {readingId:z.string().uuid(), tier, remainingAtCompletion:z.number().int().nonnegative(), replayed:z.boolean()};

export const numerologyOutput = z.object({
  schemaVersion:z.literal('1.0'), algorithm:z.string(), birthDate:z.string(), asOf:z.string(),
  lifePath:z.number().int(), personalYear:z.number().int(), personalMonth:z.number().int(),
  interpretationKeys:z.array(z.string()), disclaimer:z.string(), requestId:z.string().uuid(), ...receipt,
});
export const tarotOutput = z.object({
  schemaVersion:z.literal('1.0'), algorithm:z.string(), drawId:z.string().uuid(),
  cards:z.array(z.object({index:z.number().int(), name:z.string(), orientation:z.enum(['upright','reversed'])})),
  disclaimer:z.string(), ...receipt,
});
export const journalSchemaOutput = z.object({
  schemaVersion:z.string(), sheets:z.array(z.object({name:z.string(), headers:z.array(z.string())})),
  ownership:z.literal('user_google_drive'), instructions:z.string(), writeRules:z.array(z.string()),
});
export const feedbackOutput = z.object({saved:z.boolean(), assessment:z.literal('self_reported')});
export const reportOutput = z.object({recorded:z.boolean(), verification:z.literal('self_reported_not_independently_verified')});
