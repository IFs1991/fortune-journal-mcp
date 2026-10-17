import {NextResponse} from 'next/server';
import {readBoundedText} from '@/src/domain/security';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {webSession} from '@/src/lib/web-session';

/** Revoke one connected AI app. Supabase marks consent revoked, deletes that client's sessions and refresh tokens;
 * /api/mcp re-verifies every bearer with Auth, so its access tokens stop working immediately. */
export async function POST(req: Request) {
  if (!sameOriginPost(req, appOrigin())) return new Response('Forbidden', {status: 403});
  let clientId: string | null;
  try {
    clientId = new URLSearchParams(await readBoundedText(req, 4096)).get('client_id');
  } catch {
    return new Response('Too large', {status: 413});
  }
  if (typeof clientId !== 'string' || !/^[A-Za-z0-9_-]{1,256}$/.test(clientId))
    return new Response('Bad request', {status: 400});
  const session = await webSession();
  if (!session) return new Response('Sign in required', {status: 401});
  const {error} = await session.supabase.auth.oauth.revokeGrant({clientId});
  if (error) return new Response('Could not revoke the connection', {status: 503});
  return NextResponse.redirect(new URL('/login?connections=revoked', appOrigin()), {status: 303});
}
