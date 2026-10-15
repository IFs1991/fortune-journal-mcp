// LOCAL-ONLY MCP latency / outbound-call benchmark: local Supabase CLI stack + this app on localhost.
// Measures client-observed wall time per tool (p50/p95 by nearest rank) and counts the Auth/PostgREST
// requests the app made per call from the local Kong access log (independent of app instrumentation).
// Refuses any non-loopback target. Prints no tokens or keys; the test user is deleted at the end.
// Usage: supabase start; build+start the app (same env as e2e-local); then
//   node scripts/bench-mcp-local.mjs [--samples 40] [--warmup 5] [--label before] [--out verification/perf/before.json]
//     [--server-log <app stdout file>]  # with MCP_TIMING_LOG=true: adds server-side FJ_MCP_TIMING percentiles
import {spawnSync} from 'node:child_process';
import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {dirname} from 'node:path';
import {release,cpus} from 'node:os';
import {createClient} from '@supabase/supabase-js';
import {createServerClient} from '@supabase/ssr';

const arg=(name,fallback)=>{const i=process.argv.indexOf(`--${name}`);return i>0?process.argv[i+1]:fallback;};
const SAMPLES=Number(arg('samples',40)),WARMUP=Number(arg('warmup',5)),LABEL=arg('label','run'),OUT=arg('out',null),SERVER_LOG=arg('server-log',null);
const loopback=u=>['127.0.0.1','localhost','[::1]'].includes(new URL(u).hostname);
const status=JSON.parse(spawnSync('supabase',['status','-o','json'],{encoding:'utf8',input:''}).stdout||'{}');
const API=status.API_URL,APP=process.env.APP_ORIGIN??'http://localhost:3000';
if(!API||!loopback(API)||!loopback(APP))throw new Error('Refusing: bench-mcp-local only runs against a loopback Supabase stack and app.');
const KONG=arg('kong','supabase_kong_fortune-journal-local');
const admin=createClient(API,status.SECRET_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const anon=()=>createClient(API,status.PUBLISHABLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const ok=(cond,msg)=>{if(!cond)throw new Error(msg);};

/** Nearest-rank percentile on a sorted copy. */
function percentile(values,p){const s=[...values].sort((a,b)=>a-b);return s[Math.max(0,Math.ceil(p/100*s.length)-1)];}

// Outbound requests seen by the local API gateway. Only the app calls Kong during a measured block.
function kongLines(){
 const r=spawnSync('docker',['logs',KONG],{encoding:'utf8',maxBuffer:256*1024*1024});
 return `${r.stdout}\n${r.stderr}`.split('\n').filter(l=>/"(GET|POST|PATCH|DELETE|HEAD) \/(auth|rest)\/v1\//.test(l));
}
// Server-side timing lines written by the app (src/lib/perf.ts) since a given byte offset.
const serverLogSize=()=>SERVER_LOG?readFileSync(SERVER_LOG).length:0;
const serverTimings=from=>SERVER_LOG?readFileSync(SERVER_LOG).subarray(from).toString('utf8').split(/\r?\n/)
 .filter(l=>l.startsWith('FJ_MCP_TIMING ')).map(l=>JSON.parse(l.slice('FJ_MCP_TIMING '.length))):[];
const classify=lines=>({auth:lines.filter(l=>/ \/auth\/v1\//.test(l)).length,db:lines.filter(l=>/ \/rest\/v1\//.test(l)).length});

async function newUser(){
 const email=`fj-bench-${Date.now()}-${randomBytes(3).toString('hex')}@example.test`;
 const {data,error}=await admin.auth.admin.createUser({email,email_confirm:true});if(error)throw error;
 const {data:link,error:le}=await admin.auth.admin.generateLink({type:'magiclink',email});if(le)throw le;
 const {data:v,error:ve}=await anon().auth.verifyOtp({type:'magiclink',token_hash:link.properties.hashed_token});if(ve)throw ve;
 return {id:data.user.id,session:v.session};
}
async function cookieHeader(session){
 const jar=new Map();
 const ssr=createServerClient(API,status.PUBLISHABLE_KEY,{cookies:{getAll:()=>[...jar].map(([name,value])=>({name,value})),setAll:items=>items.forEach(({name,value})=>value?jar.set(name,value):jar.delete(name))}});
 const {error}=await ssr.auth.setSession({access_token:session.access_token,refresh_token:session.refresh_token});if(error)throw error;
 return [...jar].map(([n,v])=>`${n}=${v}`).join('; ');
}
const REDIRECT='http://localhost:9999/callback';
async function connect(user){
 const reg=await fetch(`${API}/auth/v1/oauth/clients/register`,{method:'POST',headers:{'content-type':'application/json'},
  body:JSON.stringify({client_name:'FJ Bench',redirect_uris:[REDIRECT],token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']})});
 const clientId=(await reg.json()).client_id;ok(reg.ok&&clientId,`client registration ${reg.status}`);
 const verifier=randomBytes(32).toString('base64url'),challenge=createHash('sha256').update(verifier).digest('base64url'),state=randomUUID();
 const u=new URL(`${API}/auth/v1/oauth/authorize`);
 for(const [k,v] of Object.entries({response_type:'code',client_id:clientId,redirect_uri:REDIRECT,code_challenge:challenge,code_challenge_method:'S256',scope:'openid',state}))u.searchParams.set(k,v);
 const authorizationId=new URL((await fetch(u,{redirect:'manual'})).headers.get('location')).searchParams.get('authorization_id');
 const res=await fetch(`${APP}/api/oauth/decision`,{method:'POST',redirect:'manual',headers:{'content-type':'application/x-www-form-urlencoded',cookie:await cookieHeader(user.session),origin:APP},body:new URLSearchParams({authorization_id:authorizationId,decision:'approve'})});
 ok(res.status===303,`approve ${res.status}`);
 const code=new URL(res.headers.get('location')).searchParams.get('code');
 const t=await fetch(`${API}/auth/v1/oauth/token`,{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'authorization_code',code,redirect_uri:REDIRECT,client_id:clientId,code_verifier:verifier})});
 const body=await t.json();ok(t.status===200&&body.access_token,`token ${t.status}`);return body.access_token;
}
async function call(token,name,args){
 const started=performance.now();
 const res=await fetch(`${APP}/api/mcp`,{method:'POST',headers:{'content-type':'application/json',accept:'application/json, text/event-stream','mcp-protocol-version':'2025-06-18',authorization:`Bearer ${token}`},
  body:JSON.stringify({jsonrpc:'2.0',id:randomUUID(),method:'tools/call',params:{name,arguments:args}})});
 const text=await res.text();const ms=performance.now()-started;
 const line=res.headers.get('content-type')?.includes('text/event-stream')?text.split('\n').filter(l=>l.startsWith('data:')).at(-1)?.slice(5):text;
 const result=JSON.parse(line).result;ok(res.status===200&&result,`${name} HTTP ${res.status}`);
 return {ms,error:result.isError?result.content?.[0]?.text:null,data:result.structuredContent};
}

const user=await newUser();
const report={label:LABEL,ranAt:new Date().toISOString(),
 environment:{node:process.version,os:`${process.platform} ${release()}`,cpu:cpus()[0]?.model,cpus:cpus().length,
  target:'local Supabase CLI stack (loopback, Docker) + next start on localhost',analytics:process.env.PRODUCT_ANALYTICS_ENABLED==='true'},
 method:{samples:SAMPLES,warmup:WARMUP,sequential:true,percentile:'nearest-rank',outboundCounts:'local Kong access log lines per measured block / samples'},tools:{}};
try{
 const token=await connect(user);
 // Starts the trial (first calculation) so draw_tarot is allowed, then measure every customer tool.
 ok(!(await call(token,'calculate_numerology',{birthDate:'1991-09-12',asOf:'2026-10-15',requestId:randomUUID()})).error,'trial start');
 const replayId=randomUUID();ok(!(await call(token,'draw_tarot',{count:3,drawId:replayId})).error,'replay seed');
 const {data:seed}=await admin.from('user_readings').select('id').eq('user_id',user.id).limit(1).single();
 const scenarios={
  get_account_profile:()=>({}),
  get_access_status:()=>({}),
  get_journal_schema:()=>({}),
  calculate_numerology:()=>({birthDate:'1991-09-12',asOf:'2026-10-15',requestId:randomUUID()}),
  draw_tarot:()=>({count:3,drawId:randomUUID()}),
  'draw_tarot(replay)':()=>({count:3,drawId:replayId}),
  submit_reading_feedback:()=>({readingId:seed.id,usefulness:4,matchAssessment:'unclear',explicitUserRequest:true}),
  report_journal_action:()=>({requestId:randomUUID(),action:'journal_save_reported',explicitUserRequest:true}),
 };
 for(const [scenario,args] of Object.entries(scenarios)){
  const name=scenario.replace(/\(.*\)$/,'');
  for(let i=0;i<WARMUP;i++)await call(token,name,args());
  await new Promise(r=>setTimeout(r,300));const before=kongLines().length,logFrom=serverLogSize();
  const times=[],errors={};
  for(let i=0;i<SAMPLES;i++){const r=await call(token,name,args());times.push(r.ms);if(r.error)errors[r.error]=(errors[r.error]??0)+1;}
  await new Promise(r=>setTimeout(r,300));const counted=classify(kongLines().slice(before));
  const round=x=>Math.round(x*100)/100;
  report.tools[scenario]={n:times.length,p50_ms:round(percentile(times,50)),p95_ms:round(percentile(times,95)),mean_ms:round(times.reduce((a,b)=>a+b,0)/times.length),
   min_ms:round(Math.min(...times)),max_ms:round(Math.max(...times)),auth_calls_per_call:round(counted.auth/SAMPLES),db_calls_per_call:round(counted.db/SAMPLES),
   success_rate:round((SAMPLES-Object.values(errors).reduce((a,b)=>a+b,0))/SAMPLES),errors};
  const server=serverTimings(logFrom).filter(t=>t.tool===name);
  if(server.length){const pick=k=>server.map(t=>t[k]);
   report.tools[scenario].server={n:server.length,...Object.fromEntries(['total_ms','auth_ms','db_ms','calculation_ms'].flatMap(k=>[[`${k.replace('_ms','')}_p50_ms`,round(percentile(pick(k),50))],[`${k.replace('_ms','')}_p95_ms`,round(percentile(pick(k),95))]])),
    outbound_auth_calls:round(pick('outbound_auth_calls').reduce((a,b)=>a+b,0)/server.length),outbound_db_calls:round(pick('outbound_db_calls').reduce((a,b)=>a+b,0)/server.length)};}
  console.log(scenario.padEnd(26),JSON.stringify(report.tools[scenario]));
 }
}finally{await admin.auth.admin.deleteUser(user.id).catch(()=>{});}
if(OUT){mkdirSync(dirname(OUT),{recursive:true});writeFileSync(OUT,JSON.stringify(report,null,2)+'\n');}
