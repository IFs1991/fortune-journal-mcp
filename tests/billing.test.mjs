import test from 'node:test';import assert from 'node:assert/strict';
import {validateBillingEvent} from '../src/domain/billing-event.ts';
import {resolveEntitlement} from '../src/domain/entitlements.ts';
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
