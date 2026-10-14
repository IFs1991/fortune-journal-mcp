import type {PostMetrics} from './threads.ts';
export function engagementRate(m:PostMetrics):number|null {
 if(m.views===null||m.views<=0||[m.likes,m.replies,m.reposts,m.quotes].some(x=>x===null))return null;
 return (m.likes!+m.replies!+m.reposts!+m.quotes!)/m.views*100;
}
export function percent(numerator:number,denominator:number):number|null {
 if(!Number.isSafeInteger(numerator)||!Number.isSafeInteger(denominator)||numerator<0||denominator<0||numerator>denominator)throw new Error('INVALID_COUNT');
 return denominator===0?null:numerator/denominator*100;
}
export function returnedOnD7(first:string,later:string[],asOf:string):boolean|null {
 const start=Date.parse(first),cutoff=Date.parse(asOf);
 if(!Number.isFinite(start)||!Number.isFinite(cutoff))throw new Error('INVALID_DATE');
 if(cutoff<start+8*86400000)return null; // Right-censored cohort, not a failure.
 return later.some(v=>{const d=Date.parse(v);return d>=start+7*86400000&&d<start+8*86400000&&d<=cutoff;});
}
export type Cash={currency:string;exponent:number;amountMinor:bigint;kind:'payment_succeeded'|'refund_succeeded'|'chargeback'};
export function cashByCurrency(events:Cash[]):Record<string,string> {
 const values=new Map<string,bigint>();
 for(const event of events){if(event.amountMinor<0n||!/^[A-Z]{3}$/.test(event.currency)||!Number.isInteger(event.exponent)||event.exponent<0||event.exponent>6)throw new Error('INVALID_MONEY');
  const key=`${event.currency}:${event.exponent}`;values.set(key,(values.get(key)??0n)+(event.kind==='payment_succeeded'?event.amountMinor:-event.amountMinor));}
 return Object.fromEntries([...values].map(([currency,minor])=>[currency,minor.toString()]));
}
