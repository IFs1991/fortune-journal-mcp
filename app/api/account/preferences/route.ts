import {NextResponse} from 'next/server';
import {savePreferences} from '@/src/account';
import {readBoundedText} from '@/src/domain/security';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {webSession} from '@/src/lib/web-session';
import {limitWeb} from '@/src/lib/rate-limit';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  const limited = limitWeb(request);
  if (limited) return limited;
  if (!sameOriginPost(request, appOrigin())) return new Response('Forbidden', {status: 403});
  const session = await webSession();
  if (!session) return new Response('Sign in required', {status: 401});
  let body: string;
  try {
    body = await readBoundedText(request, 8192);
  } catch {
    return new Response('Too large', {status: 413});
  }
  const outcome = await savePreferences(session.user, new URLSearchParams(body));
  if (outcome === 'analytics_disabled') return new Response('Optional analytics is disabled', {status: 503});
  if (outcome === 'unavailable') return new Response('Could not update preferences', {status: 503});
  return NextResponse.redirect(new URL('/login?preferences=saved', appOrigin()), {status: 303});
}
