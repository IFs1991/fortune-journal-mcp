import {adminSupabase} from '@/src/lib/supabase/server';
import {resolveEntitlement,type Entitlement} from '@/src/domain/entitlements';
export async function memberTier(userId:string,now=new Date()):Promise<Entitlement>{
 const db=adminSupabase();
 const {data:access,error:ae}=await db.from('user_access').select('trial_ends_at,suspended_at').eq('user_id',userId).maybeSingle();
 const {data:subs,error:se}=await db.from('subscriptions').select('status,current_period_end,verified_at').eq('user_id',userId);
 if(ae||se)throw new Error('ACCESS_BACKEND_FAILURE');
 return resolveEntitlement(access,subs??[],now);
}
