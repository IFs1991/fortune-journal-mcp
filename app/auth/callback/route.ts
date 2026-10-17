import {NextResponse} from 'next/server';
import {serverSupabase} from '@/src/lib/supabase/server';
import {safeNextPath} from '@/src/lib/urls';
import {readReferral} from '@/src/domain/security';
import {appOrigin} from '@/src/lib/env';
import {bindWebSession} from '@/src/lib/web-session';
export async function GET(request: Request) {
  const url = new URL(request.url),
    code = url.searchParams.get('code'),
    next = safeNextPath(url.searchParams.get('next'));
  if (!code || code.length > 512) return NextResponse.redirect(new URL('/login?error=auth', appOrigin()));
  const supabase = await serverSupabase();
  const {data, error} = await supabase.auth.exchangeCodeForSession(code);
  // The binding cookie marks this session as the user's own browser sign-in (src/lib/web-session.ts).
  if (error || !data.session || !(await bindWebSession(data.user.id, data.session.access_token))) {
    if (!error) await supabase.auth.signOut({scope: 'local'});
    return NextResponse.redirect(new URL('/login?error=auth', appOrigin()));
  }
  const target = new URL(next, appOrigin()),
    ref = url.searchParams.get('ref') ?? undefined;
  if (next === '/login' && readReferral(process.env.ATTRIBUTION_HMAC_KEY, ref))
    target.searchParams.set('ref', ref!);
  // No analytics cookie, IP, user-agent or raw referrer is stored here.
  return NextResponse.redirect(target, {status: 303});
}
