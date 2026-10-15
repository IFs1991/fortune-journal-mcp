import test from 'node:test';import assert from 'node:assert/strict';
import {classifyOutbound,createMeteredFetch,runWithRequestMetrics,currentRequestMetrics,measureCalculation,timingRecord} from '../src/lib/perf.ts';

const fakeFetch=(delay=5)=>async()=>{await new Promise(r=>setTimeout(r,delay));return new Response('{}');};
test('outbound requests are classified as Supabase Auth, PostgREST or other',()=>{
 assert.equal(classifyOutbound('https://p.supabase.co/auth/v1/user'),'auth');
 assert.equal(classifyOutbound('http://127.0.0.1:55421/rest/v1/rpc/fj_record_calculation'),'db');
 assert.equal(classifyOutbound(new URL('http://127.0.0.1:55421/rest/v1/user_access?select=*')),'db');
 assert.equal(classifyOutbound('https://graph.threads.net/v1.0/me'),null);
});
test('metered fetch counts and times calls only inside the current request',async()=>{
 const fetch=createMeteredFetch(fakeFetch());
 await fetch('https://p.supabase.co/auth/v1/user'); // outside any request: passes through
 const m=await runWithRequestMetrics(async()=>{
  await fetch('https://p.supabase.co/auth/v1/user');
  await fetch('https://p.supabase.co/rest/v1/rpc/x',{method:'POST'});
  await fetch('https://p.supabase.co/rest/v1/t');
  return currentRequestMetrics();
 });
 assert.equal(m.authCalls,1);assert.equal(m.dbCalls,2);
 assert.ok(m.authMs>=4&&m.dbMs>=8,`${m.authMs} ${m.dbMs}`);
});
test('concurrent requests never mix their counters',async()=>{
 const fetch=createMeteredFetch(fakeFetch(2));
 const [a,b]=await Promise.all([
  runWithRequestMetrics(async()=>{await fetch('https://p.supabase.co/rest/v1/a');return currentRequestMetrics();}),
  runWithRequestMetrics(async()=>{await Promise.all([fetch('https://p.supabase.co/auth/v1/user'),fetch('https://p.supabase.co/auth/v1/user')]);return currentRequestMetrics();}),
 ]);
 assert.deepEqual([a.authCalls,a.dbCalls,b.authCalls,b.dbCalls],[0,1,2,0]);
});
test('calculation time is attributed to the request and the value is returned',async()=>{
 const m=await runWithRequestMetrics(async()=>{assert.equal(measureCalculation(()=>42),42);return currentRequestMetrics();});
 assert.ok(m.calculationMs>=0);assert.equal(measureCalculation(()=>'outside'),'outside');
});
test('timing record holds only tool name, codes, durations and counts (no inputs, ids or tokens)',()=>{
 const metrics={startedAt:100,authMs:10.123,dbMs:5.5,calculationMs:0.25,authCalls:1,dbCalls:1};
 const ok=timingRecord('draw_tarot',metrics,{structuredContent:{cards:['x'],readingId:'r'}},130.4567);
 assert.deepEqual(ok,{tool:'draw_tarot',ok:true,error_code:null,total_ms:30.46,auth_ms:10.12,db_ms:5.5,calculation_ms:0.25,outbound_auth_calls:1,outbound_db_calls:1});
 const bad=timingRecord('draw_tarot',metrics,{isError:true,content:[{type:'text',text:'USAGE_LIMIT_REACHED'}]},130);
 assert.equal(bad.ok,false);assert.equal(bad.error_code,'USAGE_LIMIT_REACHED');
 assert.equal(timingRecord('x',metrics,{isError:true,content:[{type:'text',text:'free text 1991-09-12'}]},130).error_code,'UNKNOWN_ERROR');
 assert.deepEqual(Object.keys(ok).sort(),['auth_ms','calculation_ms','db_ms','error_code','ok','outbound_auth_calls','outbound_db_calls','tool','total_ms']);
});
