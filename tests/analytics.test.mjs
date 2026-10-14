import test from 'node:test';import assert from 'node:assert/strict';
import {normalizePostMetrics,normalizeAccountMetrics,countOrNull,dueAges,importedPost} from '../src/domain/threads.ts';
import {engagementRate,percent,returnedOnD7,cashByCurrency} from '../src/domain/metrics.ts';
const now=new Date('2026-10-14T00:00:00Z');
test('missing metrics remain null, a reported zero remains zero',()=>{
 const m=normalizePostMetrics({data:[{name:'likes',period:'lifetime',values:[{value:0}]}]});assert.equal(m.likes,0);assert.equal(m.views,null);assert.equal(engagementRate(m),null);
});
test('zero views, unknown components and incompatible periods do not produce a fake rate',()=>{
 const m=normalizePostMetrics({data:[{name:'views',period:'day',values:[{value:100}]}]});assert.equal(m.views,null);
 assert.equal(engagementRate({views:0,likes:2,replies:1,reposts:0,quotes:0,shares:1}),null);
});
test('specified engagement formula excludes shares and is not a unique-user rate',()=>{
 assert.equal(engagementRate({views:100,likes:10,replies:5,reposts:3,quotes:2,shares:90}),20);
 assert.equal(engagementRate({views:1,likes:2,replies:1,reposts:0,quotes:0,shares:null}),300);
});
test('counters reject negatives, strings, unsafe integers, and NaN',()=>{
 for(const v of [-1,'12',NaN,Infinity,2**53,0.5])assert.equal(countOrNull(v),null);assert.equal(countOrNull(0),0);
});
test('followers are stocks; daily and range metrics preserve separate boundaries',()=>{
 const payload={data:[{name:'followers_count',total_value:{value:42}},{name:'views',period:'day',values:[{value:4,end_time:'2026-10-14T00:00:00Z'}]},{name:'likes',total_value:{value:3}}]};
 const rows=normalizeAccountMetrics(payload,new Date('2026-10-13T00:00:00Z'),now);
 assert.equal(rows[0].period_start,null);assert.equal(rows[0].period_kind,'point_in_time');assert.equal(rows[1].period_kind,'day');assert.equal(rows[2].period_kind,'range');
});
test('historical counters cannot be labeled as due 24h/72h snapshots',()=>{
 assert.deepEqual(dueAges('2026-10-13T00:00:00Z',now,[]),[24]);
 assert.deepEqual(dueAges('2026-10-13T00:00:00Z',now,[24]),[]);
 assert.deepEqual(dueAges('2026-10-10T00:00:00Z',now,[]),[]);
 assert.deepEqual(dueAges('2026-10-06T23:00:00Z',now,[]),[168]);
});
test('import preserves original timestamp; skips missing text and replies',()=>{
 assert.equal(importedPost({id:'1',text:'old post',timestamp:'2025-01-01T00:00:00Z'}).published_at,'2025-01-01T00:00:00.000Z');
 assert.equal(importedPost({id:'1',text:'',timestamp:'2025-01-01T00:00:00Z'}),null);
 assert.equal(importedPost({id:'1',text:'reply',timestamp:'2025-01-01T00:00:00Z',is_reply:true}),null);
});
test('D7 is a bounded matured window, not any return in the first week',()=>{
 const first='2026-10-01T00:00:00Z';assert.equal(returnedOnD7(first,['2026-10-08T12:00:00Z'],'2026-10-09T00:00:00Z'),true);
 assert.equal(returnedOnD7(first,['2026-10-07T12:00:00Z'],'2026-10-09T00:00:00Z'),false);
 assert.equal(returnedOnD7(first,[],'2026-10-08T23:00:00Z'),null);
});
test('empty cohorts are unavailable, not zero percent',()=>{assert.equal(percent(0,0),null);assert.equal(percent(1,4),25);assert.throws(()=>percent(2,1));});
test('cash preserves integer minor units, signs, currency and exponent',()=>{
 assert.deepEqual(cashByCurrency([{currency:'USD',exponent:2,amountMinor:499n,kind:'payment_succeeded'},{currency:'USD',exponent:2,amountMinor:99n,kind:'refund_succeeded'},{currency:'JPY',exponent:0,amountMinor:500n,kind:'payment_succeeded'}]),{'USD:2':'400','JPY:0':'500'});
});
