import {NextResponse} from 'next/server';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {serverSupabase} from '@/src/lib/supabase/server';

/** Revoke one connected AI app. Supabase marks consent revoked, deletes that client's sessions and refresh tokens;
 * /api/mcp re-verifies every bearer with Auth, so its access tokens stop working immediately. */
export async function POST(req:Request) {
  if(!sameOriginPost(req,appOrigin())) return new Response('Forbidden',{status:403});
  const clientId=(await req.formData()).get('client_id');
  if(typeof clientId!=='string' || !/^[A-Za-z0-9_-]{1,256}$/.test(clientId)) return new Response('Bad request',{status:400});
  const supabase=await serverSupabase();
  const {data:{user}}=await supabase.auth.getUser();
  if(!user) return new Response('Sign in required',{status:401});
  const {error}=await supabase.auth.oauth.revokeGrant({clientId});
  if(error) return new Response('Could not revoke the connection',{status:503});
  return NextResponse.redirect(new URL('/login?connections=revoked',appOrigin()),{status:303});
}
