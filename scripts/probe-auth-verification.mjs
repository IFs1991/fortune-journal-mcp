// LOCAL-ONLY probe for the auth design decision (docs/PERFORMANCE.md §2): latency of Supabase Auth getUser()
// (network) vs getClaims() (local JWKS verification), and whether each still accepts a token after the session
// is revoked and after the user is deleted. Refuses non-loopback stacks; prints no tokens; deletes its user.
// Usage: supabase start; node scripts/probe-auth-verification.mjs [--out verification/perf/auth_probe.json]
import {spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {dirname} from 'node:path';
import {createClient} from '@supabase/supabase-js';
const s=JSON.parse(spawnSync('supabase',['status','-o','json'],{encoding:'utf8',input:''}).stdout||'{}');
if(!s.API_URL||!['127.0.0.1','localhost','[::1]'].includes(new URL(s.API_URL).hostname))throw new Error('Refusing: loopback Supabase stack only.');
const o={auth:{persistSession:false,autoRefreshToken:false}};
const admin=createClient(s.API_URL,s.SECRET_KEY,o),anon=createClient(s.API_URL,s.PUBLISHABLE_KEY,o),c=createClient(s.API_URL,s.PUBLISHABLE_KEY,o);
const email=`fj-probe-${Date.now()}@example.test`;
const {data:u,error:ue}=await admin.auth.admin.createUser({email,email_confirm:true});if(ue)throw ue;
const {data:link}=await admin.auth.admin.generateLink({type:'magiclink',email});
const {data:v}=await anon.auth.verifyOtp({type:'magiclink',token_hash:link.properties.hashed_token});
const tok=v.session.access_token,alg=JSON.parse(Buffer.from(tok.split('.')[0],'base64url').toString()).alg;
const pct=(a,q)=>{const x=[...a].sort((m,n)=>m-n);return Math.round(x[Math.max(0,Math.ceil(q/100*x.length)-1)]*100)/100;};
async function bench(fn,n=100){for(let i=0;i<5;i++)await fn();const t=[];for(let i=0;i<n;i++){const a=performance.now();await fn();t.push(performance.now()-a);}return {n,p50_ms:pct(t,50),p95_ms:pct(t,95)};}
const accepted=async()=>({getUser:!(await c.auth.getUser(tok)).error,getClaims:!(await c.auth.getClaims(tok)).error});
const out={ranAt:new Date().toISOString(),node:process.version,tokenAlg:alg,
 latency:{getUser:await bench(()=>c.auth.getUser(tok)),getClaims:await bench(()=>c.auth.getClaims(tok))},acceptedWhileValid:await accepted()};
await admin.auth.admin.signOut(tok,'global');out.acceptedAfterSessionRevoked=await accepted();
await admin.auth.admin.deleteUser(u.user.id);out.acceptedAfterUserDeleted=await accepted();
console.log(JSON.stringify(out,null,1));
const i=process.argv.indexOf('--out');if(i>0){mkdirSync(dirname(process.argv[i+1]),{recursive:true});writeFileSync(process.argv[i+1],JSON.stringify(out,null,2)+'\n');}
