import {z} from 'zod';
import {readBoundedText,verifyOps} from '@/src/domain/security';
import {draftPost,approvePost,publishPost,collectPost,collectAccount,importPosts,report,referralLink,recordRunCost,recordExternalRun} from '@/src/lib/operations';
export const runtime='nodejs';export const dynamic='force-dynamic';export const maxDuration=60;
const id=z.string().uuid(),label=z.string().regex(/^[A-Za-z0-9_.:-]{1,80}$/);
const base={requestId:id};
const schema=z.discriminatedUnion('action',[
 z.object({...base,action:z.literal('draft_post'),body:z.string().min(1).refine(s=>[...s].length<=500),topic:z.enum(['love','work','money','general']),method:z.enum(['tarot','numerology','mixed']),tone:z.enum(['empathetic','assertive','question']),language:z.string().regex(/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$/),hookText:z.string().max(240).optional(),ctaKey:z.enum(['none','reflect','save','reply','visit_profile']),promptVersion:label,experimentId:label.optional(),variantKey:label.optional(),scheduledAt:z.string().datetime().optional(),zodiac:z.enum(['aries','taurus','gemini','cancer','leo','virgo','libra','scorpio','sagittarius','capricorn','aquarius','pisces']).optional()}).strict(),
 z.object({...base,action:z.literal('approve_post'),postId:id,bodySha256:z.string().regex(/^[a-f0-9]{64}$/)}).strict(),
 z.object({...base,action:z.literal('publish_post'),postId:id}).strict(),
 z.object({...base,action:z.literal('collect_post_metrics'),postId:id,kind:z.enum(['manual','backfill_now']).default('manual')}).strict(),
 z.object({...base,action:z.literal('collect_account_metrics'),since:z.string().datetime(),until:z.string().datetime()}).strict(),
 z.object({...base,action:z.literal('import_posts'),after:z.string().max(2048).optional()}).strict(),
 z.object({...base,action:z.literal('report'),from:z.string().datetime(),until:z.string().datetime()}).strict(),
 z.object({...base,action:z.literal('referral_link'),postId:id}).strict(),
 z.object({...base,action:z.literal('record_external_run'),task:z.enum(['weekly_analysis','draft_post']),startedAt:z.string().datetime(),finishedAt:z.string().datetime(),success:z.boolean(),errorCode:z.string().regex(/^[A-Z0-9_]{1,80}$/).optional(),model:z.string().max(120).optional(),inputTokens:z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),outputTokens:z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),estimatedCost:z.number().nonnegative().max(1000000).optional(),currency:z.string().regex(/^[A-Z]{3}$/).optional()}).strict(),
 z.object({...base,action:z.literal('record_run_cost'),runId:id,model:z.string().max(120).optional(),inputTokens:z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),outputTokens:z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(),estimatedCost:z.number().nonnegative().max(1000000).optional(),currency:z.string().regex(/^[A-Z]{3}$/).optional()}).strict(),
]);
export async function POST(request:Request){
 if(process.env.OPERATIONS_ENABLED!=='true')return Response.json({error:'OPERATIONS_DISABLED'},{status:503});
 if(!request.headers.get('content-type')?.startsWith('application/json')||new URL(request.url).search)return Response.json({error:'INVALID_REQUEST'},{status:400});
 let body:string;try{body=await readBoundedText(request);}catch{return Response.json({error:'BODY_TOO_LARGE'},{status:413});}
 if(!verifyOps(process.env.OPS_HMAC_KEY,'POST',new URL(request.url).pathname,request.headers.get('x-fj-timestamp'),request.headers.get('x-fj-signature'),body))return Response.json({error:'UNAUTHORIZED'},{status:401});
 let command:z.infer<typeof schema>;try{command=schema.parse(JSON.parse(body));}catch{return Response.json({error:'INVALID_COMMAND'},{status:400});}
 try{let value:unknown;switch(command.action){
 case 'draft_post':value=await draftPost(command.requestId,command);break;
 case 'approve_post':value=await approvePost(command.postId,command.bodySha256);break;
 case 'publish_post':value=await publishPost(command.postId);break;
 case 'collect_post_metrics':value=await collectPost(command.postId,command.requestId,null,command.kind);break;
 case 'collect_account_metrics':value=await collectAccount(command.requestId,command.since,command.until);break;
 case 'import_posts':value=await importPosts(command.requestId,command.after);break;
 case 'report':value=await report(command.from,command.until);break;
 case 'referral_link':value=await referralLink(command.postId);break;
 case 'record_external_run':value=await recordExternalRun(command.requestId,command);break;
 case 'record_run_cost':value=await recordRunCost(command.runId,command);break;
 }
 return Response.json(value,{headers:{'Cache-Control':'no-store'}});
 }catch(e){
 const allowed=['PUBLISH_DISABLED','INSIGHTS_DISABLED','THREADS_NOT_CONFIGURED','POST_NOT_APPROVED','IDEMPOTENCY_CONFLICT','THREADS_RATE_LIMITED','THREADS_PERMISSION_DENIED','POST_NOT_FOUND'];
 const code=e instanceof Error&&allowed.includes(e.message)?e.message:'OPERATION_FAILED';
 console.error(JSON.stringify({code:'FJ_OPS_FAILED',requestId:command.requestId,action:command.action}));
 return Response.json({error:code},{status:code.includes('DISABLED')?503:409});
 }
}
