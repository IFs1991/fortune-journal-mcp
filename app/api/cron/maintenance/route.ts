import {secureEqual,requireSecret} from '@/src/domain/security';
import {maintenance} from '@/src/lib/operations';
export const runtime='nodejs';export const dynamic='force-dynamic';export const maxDuration=60;
export async function GET(request:Request){
 let secret:string;try{secret=requireSecret(process.env.CRON_SECRET);}catch{console.error(JSON.stringify({code:'FJ_CRON_NOT_CONFIGURED'}));return Response.json({error:'NOT_CONFIGURED'},{status:503});}
 if(!secureEqual(request.headers.get('authorization')??'',`Bearer ${secret}`))return Response.json({error:'UNAUTHORIZED'},{status:401});
 try{
  const value=await maintenance();
  // One greppable line per run so a Vercel log drain/alert can detect partial failures (no secrets or payloads).
  const failed=JSON.stringify(value).match(/"errorCode":"[A-Z_]+"|"purged":false/g)??[];
  console[failed.length?'error':'info'](JSON.stringify({code:failed.length?'FJ_MAINTENANCE_PARTIAL_FAILURE':'FJ_MAINTENANCE_OK',failures:failed.length}));
  return Response.json(value,{headers:{'Cache-Control':'no-store'}});
 }catch(e){
  console.error(JSON.stringify({code:'FJ_MAINTENANCE_FAILED',reason:e instanceof Error&&/^[A-Z_]+$/.test(e.message)?e.message:'UNEXPECTED'}));
  return Response.json({error:'MAINTENANCE_FAILED'},{status:503});
 }
}
