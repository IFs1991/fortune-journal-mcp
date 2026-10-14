import test from 'node:test';import assert from 'node:assert/strict';
import {ThreadsClient} from '../src/integrations/threads.ts';
const config={accountId:'123',accessToken:'test-token-not-live',apiVersion:'v1.0'};
test('insights credentials are headers, not URL query strings',async()=>{
 const calls=[];const fake=async(url,options)=>{calls.push([String(url),options]);return Response.json({data:[{name:'likes',period:'lifetime',values:[{value:3}]}]});};
 const out=await new ThreadsClient(config,fake).postMetrics('456');assert.equal(out.likes,3);assert(!calls[0][0].includes('test-token'));assert.equal(calls[0][1].headers.Authorization,'Bearer test-token-not-live');
});
test('followers fetch omits time filters and period metrics explicitly include them',async()=>{
 const urls=[];const fake=async(url)=>{urls.push(new URL(url));return Response.json({data:[]});};
 await new ThreadsClient(config,fake).accountMetrics(new Date('2026-10-13T00:00:00Z'),new Date('2026-10-14T00:00:00Z'));
 assert.equal(urls[0].searchParams.has('since'),false);assert.equal(urls[1].searchParams.has('since'),true);
});
test('remote publish is never automatically retried on transport uncertainty',async()=>{
 let attempts=0;const fake=async()=>{attempts++;throw new Error('lost response');};
 await assert.rejects(()=>new ThreadsClient(config,fake).publishContainer('1'),/THREADS_NETWORK_ERROR/);assert.equal(attempts,1);
});
test('returned next URL cannot redirect the client to another host',async()=>{
 let seen;const fake=async(url)=>{seen=String(url);return Response.json({data:[],paging:{next:'http://127.0.0.1/secrets',cursors:{after:'cursor-value'}}});};
 const result=await new ThreadsClient(config,fake).listPosts();assert.equal(result.nextCursor,'cursor-value');assert(seen.startsWith('https://graph.threads.net/'));
});
test('429 and permissions are distinct safe error codes',async()=>{
 await assert.rejects(()=>new ThreadsClient(config,async()=>new Response('',{status:429})).postMetrics('1'),/THREADS_RATE_LIMITED/);
 await assert.rejects(()=>new ThreadsClient(config,async()=>new Response('',{status:403})).postMetrics('1'),/THREADS_PERMISSION_DENIED/);
});
test('malformed IDs and overlong text cannot become remote paths or posts',async()=>{
 const api=new ThreadsClient(config,async()=>{throw new Error('must not reach fetch');});
 await assert.rejects(()=>api.postMetrics('../secrets'),/INVALID_POST_ID/);await assert.rejects(()=>api.createTextContainer('x'.repeat(501)),/INVALID_POST_LENGTH/);
});
