import {NextResponse} from 'next/server';
import {readBoundedText} from '@/src/domain/security';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {webSession} from '@/src/lib/web-session';

export async function POST(req: Request) {
  if (!sameOriginPost(req, appOrigin())) return new Response('Forbidden', {status: 403});
  let form: URLSearchParams;
  try {
    form = new URLSearchParams(await readBoundedText(req, 4096));
  } catch {
    return new Response('Too large', {status: 413});
  }
  const authorizationId = form.get('authorization_id');
  const decision = form.get('decision');
  if (
    typeof authorizationId !== 'string' ||
    !/^[A-Za-z0-9_-]{5,256}$/.test(authorizationId) ||
    (decision !== 'approve' && decision !== 'deny')
  )
    return new Response('Bad request', {status: 400});
  const session = await webSession();
  if (!session) return new Response('Sign in required', {status: 401});
  const {supabase} = session;
  // Supabase binds authorizationId to the requesting OAuth client and user.
  const {data: details, error: detailError} =
    await supabase.auth.oauth.getAuthorizationDetails(authorizationId);
  if (detailError || !details || !('authorization_id' in details))
    return new Response('Invalid authorization', {status: 400});
  const {data, error} =
    decision === 'approve'
      ? await supabase.auth.oauth.approveAuthorization(authorizationId)
      : await supabase.auth.oauth.denyAuthorization(authorizationId);
  if (error || !data?.redirect_url) return new Response('Authorization failed', {status: 400});
  const target = new URL(data.redirect_url);
  // Redirect URL is generated/validated by Supabase OAuth Server, never from the POST body.
  if (!['https:', 'http:'].includes(target.protocol)) return new Response('Invalid callback', {status: 400});
  return NextResponse.redirect(target, {status: 303});
}
