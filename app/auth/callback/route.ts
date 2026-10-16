import {NextResponse} from 'next/server';
import {serverSupabase} from '@/src/lib/supabase/server';
import {safeNextPath} from '@/src/lib/urls';
import {readReferral} from '@/src/domain/security';
import {appOrigin} from '@/src/lib/env';
export async function GET(request: Request) {
  const url = new URL(request.url),
    code = url.searchParams.get('code'),
    next = safeNextPath(url.searchParams.get('next'));
  if (!code) return NextResponse.redirect(new URL('/login?error=auth', appOrigin()));
  const {error} = await (await serverSupabase()).auth.exchangeCodeForSession(code);
  if (error) return NextResponse.redirect(new URL('/login?error=auth', appOrigin()));
  const target = new URL(next, appOrigin()),
    ref = url.searchParams.get('ref') ?? undefined;
  if (next === '/login' && readReferral(process.env.ATTRIBUTION_HMAC_KEY, ref))
    target.searchParams.set('ref', ref!);
  // No analytics cookie, IP, user-agent or raw referrer is stored here.
  return NextResponse.redirect(target, {status: 303});
}
