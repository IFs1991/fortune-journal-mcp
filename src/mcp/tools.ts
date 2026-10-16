import type {CallToolResult, McpServer, ServerContext, ToolAnnotations} from '@modelcontextprotocol/server';
import type {z} from 'zod';
import {getAuthenticatedUserId} from '@/src/lib/oauth';
import {timedTool} from '@/src/lib/perf';
import {accessStatusTool, accountProfileTool} from '@/src/mcp/account';
import {journalActionTool, journalSchemaTool, readingFeedbackTool} from '@/src/mcp/journal';
import {calculateNumerologyTool, drawTarotTool} from '@/src/mcp/readings';
import {toolError} from '@/src/mcp/response';
import * as schemas from '@/src/mcp/schemas';

/**
 * The complete customer MCP API. Every tool requires an OAuth bearer verified by Supabase Auth (src/lib/oauth.ts)
 * and receives only the verified user id, never a user id from its arguments. Operator commands live in
 * src/ops/ behind a separate HMAC API and are never registered here.
 */
export const SERVER_INSTRUCTIONS =
  'Fortune Journal supplies deterministic entertainment-oriented fortune calculations. Do not present fortunes as ' +
  'factual predictions. For a reading, call calculate_numerology or draw_tarot directly: they enforce access and ' +
  'report tier and remaining usage, so get_account_profile and get_access_status are only for when the user asks ' +
  'about their account or plan. Records belong in the user’s own connected Google Sheets app, only when requested ' +
  'or authorized; this server never reads or writes Google. Keep fortune results, life events and retrospective ' +
  'interpretation separate; never edit an original reading to match later events. Use the feedback and report ' +
  'tools only after an explicit user request (optional analytics consent is given on the web, never inferred). ' +
  'Do not advertise purchases or include checkout links.';

export type ToolContext = {userId: string; clientId: string | undefined};

type ToolDefinition<Input extends z.ZodObject> = {
  name: string;
  title: string;
  description: string;
  input: Input;
  output: z.ZodObject;
  /** Read-only tools write nothing; no tool deletes or reaches outside this service. */
  readOnly: boolean;
  run: (args: z.infer<Input>, context: ToolContext) => Promise<CallToolResult>;
  /** Code returned when the backend fails unexpectedly (other codes come from run). */
  unavailableCode: string;
};

const tools = [
  tool({
    name: 'get_account_profile',
    title: 'Get Connected Account',
    description:
      'Return a stable, non-sensitive account ID for the connected Fortune Journal user (no email, no journal ' +
      'contents). Call only when the user asks which account is connected; not needed before a reading.',
    input: schemas.noInput,
    output: schemas.accountProfileOutput,
    readOnly: false, // records consented connection telemetry
    run: accountProfileTool,
    unavailableCode: 'SERVICE_TEMPORARILY_UNAVAILABLE',
  }),
  tool({
    name: 'get_access_status',
    title: 'Check Access',
    description:
      'Return the current plan tier (free, trial, premium or suspended). Call only when the user asks about their ' +
      'plan or access; readings check access themselves. Never starts a purchase or returns a checkout link.',
    input: schemas.noInput,
    output: schemas.accessStatusOutput,
    readOnly: true,
    run: accessStatusTool,
    unavailableCode: 'ACCESS_TEMPORARILY_UNAVAILABLE',
  }),
  tool({
    name: 'get_journal_schema',
    title: 'Get Personal Journal Template',
    description:
      'Return sheet names, column headers and write rules for a Fortune Journal workbook. This tool never accesses ' +
      'Google Drive. To save, ask the user’s own Google Sheets app to write to their account with their consent.',
    input: schemas.noInput,
    output: schemas.journalSchemaOutput,
    readOnly: true,
    run: journalSchemaTool,
    unavailableCode: 'SERVICE_TEMPORARILY_UNAVAILABLE',
  }),
  tool({
    name: 'calculate_numerology',
    title: 'Calculate Personal Numerology',
    description:
      'Calculate life-path, personal-year and personal-month numbers from a birth date with the deterministic ' +
      'fj-numerology-v1 convention. Call it directly (it checks access and returns tier and remainingAtCompletion; ' +
      'Free has a weekly quota). The birth date is processed for this request only and never saved. Entertainment ' +
      'and reflection only, not a prediction. Errors: INVALID_DATE, USAGE_LIMIT_REACHED, IDEMPOTENCY_CONFLICT, ' +
      'ACCOUNT_SUSPENDED.',
    input: schemas.numerologyInput,
    output: schemas.numerologyOutput,
    readOnly: false,
    run: calculateNumerologyTool,
    unavailableCode: 'SERVICE_TEMPORARILY_UNAVAILABLE',
  }),
  tool({
    name: 'draw_tarot',
    title: 'Draw Symbolic Tarot Cards',
    description:
      'Trial or Premium: draw one or three symbolic Major Arcana cards. Call it directly (Free accounts get ' +
      'FEATURE_NOT_INCLUDED). The same drawId always returns the same cards and does not use another unit within ' +
      'the 90-day window; omit drawId for a new draw. No question text or reading contents are stored. ' +
      'Entertainment only. Errors: FEATURE_NOT_INCLUDED, USAGE_LIMIT_REACHED, IDEMPOTENCY_CONFLICT, ACCOUNT_SUSPENDED.',
    input: schemas.tarotInput,
    output: schemas.tarotOutput,
    readOnly: false,
    run: drawTarotTool,
    unavailableCode: 'SERVICE_TEMPORARILY_UNAVAILABLE',
  }),
  tool({
    name: 'submit_reading_feedback',
    title: 'Submit Optional Reading Feedback',
    description:
      'Only after the user explicitly asks to send feedback: save a 1–5 usefulness rating and a fixed-label match ' +
      'assessment for one of their readings. Needs optional analytics consent given on the login page ' +
      '(otherwise OPTIONAL_ANALYTICS_DISABLED). Never send journal text. A match is a subjective report, not ' +
      'evidence of predictive accuracy.',
    input: schemas.feedbackInput,
    output: schemas.feedbackOutput,
    readOnly: false,
    run: readingFeedbackTool,
    unavailableCode: 'FEEDBACK_NOT_ACCEPTED',
  }),
  tool({
    name: 'report_journal_action',
    title: 'Report an Optional Journal Action',
    description:
      'Only on an explicit user request with optional analytics consent: note that the user reports a journal save, ' +
      'life-log entry or review. Cannot verify Google Sheets and never records document contents or file IDs. Never ' +
      'call it to manufacture a success metric.',
    input: schemas.journalActionInput,
    output: schemas.journalActionOutput,
    readOnly: false,
    run: journalActionTool,
    unavailableCode: 'REPORT_NOT_ACCEPTED',
  }),
];

export function registerTools(server: McpServer): void {
  for (const register of tools) register(server);
}

const OAUTH_REQUIRED = {securitySchemes: [{type: 'oauth2', scopes: [] as string[]}]};

/** Binds one definition to the SDK: auth gate, timing log, and a fail-closed error code. */
function tool<Input extends z.ZodObject>(definition: ToolDefinition<Input>) {
  const annotations: ToolAnnotations = {
    readOnlyHint: definition.readOnly,
    destructiveHint: false,
    openWorldHint: false,
  };
  // Widened to the base schema type so the SDK's conditional callback type resolves.
  const inputSchema: z.ZodObject = definition.input;
  return (server: McpServer) =>
    server.registerTool(
      definition.name,
      {
        title: definition.title,
        description: definition.description,
        inputSchema,
        outputSchema: definition.output,
        annotations,
        _meta: OAUTH_REQUIRED,
      },
      // The SDK has already validated args against definition.input before calling back.
      timedTool(definition.name, async (args: unknown, ctx: ServerContext) => {
        const userId = getAuthenticatedUserId(ctx);
        if (!userId) return toolError('AUTHENTICATION_REQUIRED');
        try {
          return await definition.run(args as z.infer<Input>, {
            userId,
            clientId: ctx.http?.authInfo?.clientId,
          });
        } catch {
          return toolError(definition.unavailableCode);
        }
      }),
    );
}
