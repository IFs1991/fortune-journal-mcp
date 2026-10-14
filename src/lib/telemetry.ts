import {adminSupabase} from '@/src/lib/supabase/server';
export const PRIVACY_VERSION='2026-10-v2';
export function platformForClient(clientId:string|undefined):'chatgpt'|'claude'|'unknown'{
 try {const mapping=JSON.parse(process.env.MCP_CLIENT_NAMES_JSON??'{}');const value=clientId?mapping[clientId]:undefined;return value==='chatgpt'||value==='claude'?value:'unknown';}catch{return 'unknown';}
}
export async function recordConnection(userId:string,clientId:string|undefined):Promise<void>{
 if(process.env.PRODUCT_ANALYTICS_ENABLED!=='true')return;
 const channel=platformForClient(clientId);
 const {error}=await adminSupabase().rpc('fj_record_funnel',{p_user_id:userId,p_event:'mcp_connected',p_dedupe_key:`connected:${channel}`,p_channel:channel,p_evidence:channel==='unknown'?'unknown':'registered_client'});
 if(error)throw new Error('TELEMETRY_BACKEND_FAILURE');
}
