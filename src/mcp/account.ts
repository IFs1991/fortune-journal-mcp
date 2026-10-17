import {after} from 'next/server';
import {clientPlatform, isEnabled} from '@/src/lib/env';
import {adminSupabase} from '@/src/lib/supabase/server';
import {result} from '@/src/mcp/response';
import {accessStatusOutput} from '@/src/mcp/schemas';
import type {ToolContext} from '@/src/mcp/tools';

export async function accountProfileTool(_args: unknown, context: ToolContext) {
  if (isEnabled('PRODUCT_ANALYTICS_ENABLED')) {
    // Runs after the response is sent. fj_record_funnel re-checks consent and dedupes per platform.
    after(() =>
      recordConnection(context).catch(() => {
        console.warn('FJ_CONNECTION_TELEMETRY_UNAVAILABLE');
      }),
    );
  }
  return result({id: context.userId, name: 'Fortune Journal'});
}

async function recordConnection(context: ToolContext): Promise<void> {
  const platform = clientPlatform(context.clientId);
  const {error} = await adminSupabase().rpc('fj_record_funnel', {
    p_user_id: context.userId,
    p_event: 'mcp_connected',
    p_dedupe_key: `connected:${platform}`,
    p_channel: platform,
    p_evidence: platform === 'unknown' ? 'unknown' : 'registered_client',
  });
  if (error) throw new Error('TELEMETRY_BACKEND_FAILURE');
}

/** The tier rule lives in the database (fj_access_status), the same function the calculations use. */
export async function accessStatusTool(_args: unknown, context: ToolContext) {
  const {data, error} = await adminSupabase().rpc('fj_access_status', {p_user_id: context.userId});
  const status = accessStatusOutput.safeParse({tier: data});
  if (error || !status.success) throw new Error('ACCESS_BACKEND_FAILURE');
  return result(status.data);
}
