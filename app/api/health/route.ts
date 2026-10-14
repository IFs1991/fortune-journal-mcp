export const dynamic='force-dynamic';
export function GET(){return Response.json({status:'up',version:'0.2.0',billing:'not_connected'},{headers:{'Cache-Control':'no-store'}});}
