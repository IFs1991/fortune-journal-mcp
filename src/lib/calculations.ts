import {adminSupabase} from '@/src/lib/supabase/server';
import {requestFingerprint,requireSecret} from '@/src/domain/security';
export type CalculationReceipt={ok:boolean;readingId?:string;tier?:'free'|'trial'|'premium';remainingAtCompletion?:number;replayed?:boolean;reason?:string};
export async function recordCalculation(input:{userId:string;requestId:string;feature:'calculate_numerology'|'draw_tarot';algorithm:string;targetDate:string;orderedInput:unknown[];topic?:string;client?:string}):Promise<CalculationReceipt>{
 const fingerprint=requestFingerprint(requireSecret(process.env.REQUEST_HMAC_KEY),input.userId,input.requestId,input.feature,input.orderedInput);
 const {data,error}=await adminSupabase().rpc('fj_record_calculation',{
  p_user_id:input.userId,p_request_id:input.requestId,p_fingerprint:fingerprint,p_feature:input.feature,
  p_algorithm:input.algorithm,p_target_date:input.targetDate,
  p_collect_analytics:process.env.PRODUCT_ANALYTICS_ENABLED==='true',
  p_topic:process.env.PRODUCT_ANALYTICS_ENABLED==='true'?(input.topic??null):null,p_client:input.client??'unknown',
 });
 if(error||!data||typeof data.ok!=='boolean')throw new Error('USAGE_BACKEND_FAILURE');return data as CalculationReceipt;
}
