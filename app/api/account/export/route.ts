import {serverSupabase,adminSupabase} from '@/src/lib/supabase/server';
export const runtime='nodejs';export const dynamic='force-dynamic';
const resources={
 access:{table:'user_access',columns:'user_id,trial_started_at,trial_ends_at,suspended_at,analytics_consent_at,interest_consent_at,consent_version,consent_updated_at,analytics_revoked_at,first_calculated_at,created_at',time:'created_at',order:'user_id'},
 subscriptions:{table:'subscriptions',columns:'id,provider,provider_subscription_id,status,current_period_end,cancel_at_period_end,plan_key,amount_minor,currency,currency_exponent,interval_months,created_at',time:'created_at',order:'id'},
 readings:{table:'user_readings',columns:'id,request_id,feature_key,algorithm_version,target_date,topic,tier_at_use,calculated_at',time:'calculated_at',order:'id'},
 feedback:{table:'reading_feedback',columns:'id,reading_id,usefulness,match_assessment,followup_date,created_at,updated_at',time:'created_at',order:'id'},
 events:{table:'funnel_events',columns:'id,event_name,occurred_at,received_at,source_channel,source_evidence,observation,post_id,experiment_id,reading_id',time:'received_at',order:'id'},
 billing:{table:'billing_events',columns:'provider,event_id,event_type,occurred_at,received_at,amount_minor,currency,currency_exponent,billing_reason,processing_status',time:'received_at',order:'event_id'},
} as const;
export async function GET(request:Request){
 const {data:{user}}=await(await serverSupabase()).auth.getUser();if(!user)return Response.json({error:'UNAUTHORIZED'},{status:401});
 const url=new URL(request.url),name=url.searchParams.get('resource')??'access';
 if(!(name in resources))return Response.json({error:'INVALID_RESOURCE'},{status:400});
 const offset=Number(url.searchParams.get('offset')??'0'),asOf=url.searchParams.get('asOf')??new Date().toISOString();
 if(!Number.isSafeInteger(offset)||offset<0||offset>1000000||!Number.isFinite(Date.parse(asOf))||Date.parse(asOf)>Date.now()+300000)return Response.json({error:'INVALID_PAGE'},{status:400});
 const def=resources[name as keyof typeof resources];
 let query=adminSupabase().from(def.table).select(def.columns).eq('user_id',user.id).lte(def.time,asOf).order(def.order);
 if(name==='billing')query=query.order('provider');
 const {data,error}=await query.range(offset,offset+100);
 if(error)return Response.json({error:'EXPORT_FAILED'},{status:503});
 const rows=data??[];return Response.json({resource:name,asOf,rows:rows.slice(0,100),hasMore:rows.length>100,nextOffset:rows.length>100?offset+100:null,
 availableResources:Object.keys(resources),note:'Paged export of service data only. Your journal is in your Google account. No request fingerprint, OAuth token or payment credential is exported.'},
 {headers:{'Cache-Control':'no-store','Content-Disposition':`attachment; filename="fortune-journal-${name}-${offset}.json"`}});
}
