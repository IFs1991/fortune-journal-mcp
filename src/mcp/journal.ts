import type {z} from 'zod';
import {
  JOURNAL_INSTRUCTIONS,
  JOURNAL_SCHEMA_VERSION,
  JOURNAL_SHEETS,
  JOURNAL_WRITE_RULES,
} from '@/src/domain/journal';
import {parseISODate} from '@/src/domain/numerology';
import {isEnabled} from '@/src/lib/env';
import {adminSupabase} from '@/src/lib/supabase/server';
import {result, toolError} from '@/src/mcp/response';
import type {feedbackInput, journalActionInput} from '@/src/mcp/schemas';
import type {ToolContext} from '@/src/mcp/tools';

/** Static template for the user's own Google Sheets connector. Fortune Journal never touches Google. */
export async function journalSchemaTool() {
  return result({
    schemaVersion: JOURNAL_SCHEMA_VERSION,
    sheets: JOURNAL_SHEETS.map((sheet) => ({name: sheet.name, headers: [...sheet.headers]})),
    ownership: 'user_google_drive',
    instructions: JOURNAL_INSTRUCTIONS,
    writeRules: [...JOURNAL_WRITE_RULES],
  });
}

export async function readingFeedbackTool(args: z.infer<typeof feedbackInput>, context: ToolContext) {
  if (!isEnabled('PRODUCT_ANALYTICS_ENABLED')) return toolError('OPTIONAL_ANALYTICS_DISABLED');
  if (args.followupDate) parseISODate(args.followupDate);
  const {data, error} = await adminSupabase().rpc('fj_submit_feedback', {
    p_user_id: context.userId,
    p_reading_id: args.readingId,
    p_usefulness: args.usefulness,
    p_match: args.matchAssessment,
    p_followup: args.followupDate ?? null,
  });
  if (error) throw new Error('FEEDBACK_BACKEND_REFUSED');
  // false = the user has not given (or has withdrawn) optional analytics consent.
  if (data !== true) return toolError('OPTIONAL_ANALYTICS_DISABLED');
  return result({saved: true, assessment: 'self_reported'});
}

export async function journalActionTool(args: z.infer<typeof journalActionInput>, context: ToolContext) {
  if (!isEnabled('PRODUCT_ANALYTICS_ENABLED')) return toolError('OPTIONAL_ANALYTICS_DISABLED');
  const {data, error} = await adminSupabase().rpc('fj_record_funnel', {
    p_user_id: context.userId,
    p_event: args.action,
    p_dedupe_key: `report:${args.requestId}`,
    p_reading_id: args.readingId ?? null,
  });
  if (error) throw new Error('REPORT_BACKEND_REFUSED');
  return result({recorded: data === true, verification: 'self_reported_not_independently_verified'});
}
