import {secureEqual,requireSecret} from '@/src/domain/security';
import {maintenance} from '@/src/lib/operations';
export const runtime='nodejs';export const dynamic='force-dynamic';export const maxDuration=60;
export async function GET(request:Request){
 let secret:string;try{secret=requireSecret(process.env.CRON_SECRET);}catch{return Response.json({error:'NOT_CONFIGURED'},{status:503});}
 if(!secureEqual(request.headers.get('authorization')??'',`Bearer ${secret}`))return Response.json({error:'UNAUTHORIZED'},{status:401});
 try{return Response.json(await maintenance(),{headers:{'Cache-Control':'no-store'}});}catch{return Response.json({error:'MAINTENANCE_FAILED'},{status:503});}
}
