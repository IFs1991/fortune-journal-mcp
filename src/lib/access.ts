import {adminSupabase} from '@/src/lib/supabase/server';
import {entitlementFromSnapshot, type Entitlement} from '@/src/domain/entitlements';
/** One read-only RPC (migration 08) instead of separate user_access and subscriptions reads. */
export async function memberTier(userId: string, now = new Date()): Promise<Entitlement> {
  const {data, error} = await adminSupabase().rpc('fj_access_snapshot', {p_user_id: userId});
  if (error) throw new Error('ACCESS_BACKEND_FAILURE');
  return entitlementFromSnapshot(data, now);
}
