import test from 'node:test';import assert from 'node:assert/strict';
import {validateBillingEvent} from '../src/domain/billing-event.ts';
import {resolveEntitlement,entitlementFromSnapshot} from '../src/domain/entitlements.ts';
const e={event_type:'payment_succeeded',provider_subscription_id:'sub_test',occurred_at:'2026-10-14T00:00:00Z',economic_key:'charge:1',original_payment_key:null,amount_minor:499,currency:'USD',currency_exponent:2,billing_reason:'initial',plan_key:'premium',subscription:null};
test('normalized billing preserves amounts; rejects unsafe numbers and missing currency scale',()=>{
 assert.equal(validateBillingEvent(e).amount_minor,499);for(const amount_minor of [-1,1.5,2**53])assert.throws(()=>validateBillingEvent({...e,amount_minor}));assert.throws(()=>validateBillingEvent({...e,currency_exponent:null}));
});
test('non-financial notifications do not count as cash',()=>{assert.throws(()=>validateBillingEvent({...e,event_type:'subscription_updated'}));});
test('only verified current subscription snapshots grant Premium',()=>{
 const now=new Date('2026-10-14T00:00:00Z');const subscription={status:'active',current_period_end:'2026-11-01T00:00:00Z'};
 assert.equal(resolveEntitlement(null,[subscription],now),'free');assert.equal(resolveEntitlement(null,[{...subscription,verified_at:'2026-10-13T00:00:00Z'}],now),'premium');
 assert.equal(resolveEntitlement({trial_ends_at:null,suspended_at:'2026-10-13T00:00:00Z'},[{...subscription,verified_at:'2026-10-13T00:00:00Z'}],now),'suspended');
});
test('access snapshot RPC result resolves exactly like the former two-query read, and malformed data fails closed',()=>{
 const now=new Date('2026-10-14T00:00:00Z'),verified={status:'active',current_period_end:'2026-11-01T00:00:00+00:00',verified_at:'2026-10-01T00:00:00+00:00'};
 assert.equal(entitlementFromSnapshot({access:null,subscriptions:[]},now),'free');
 assert.equal(entitlementFromSnapshot({access:null,subscriptions:[verified]},now),'premium');
 assert.equal(entitlementFromSnapshot({access:{trial_ends_at:'2026-10-20T00:00:00+00:00',suspended_at:null},subscriptions:[]},now),'trial');
 assert.equal(entitlementFromSnapshot({access:{trial_ends_at:null,suspended_at:'2026-10-13T00:00:00+00:00'},subscriptions:[verified]},now),'suspended');
 for(const bad of [null,'free',{},{access:null},{access:null,subscriptions:{}},{access:{trial_ends_at:1,suspended_at:null},subscriptions:[]},{access:null,subscriptions:[{status:7}]}])
  assert.throws(()=>entitlementFromSnapshot(bad,now),/ACCESS_BACKEND_FAILURE/,JSON.stringify(bad));
});
