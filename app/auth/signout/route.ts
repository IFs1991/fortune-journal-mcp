import {NextResponse} from 'next/server';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {serverSupabase} from '@/src/lib/supabase/server';
import {clearWebSessionBinding} from '@/src/lib/web-session';
export async function POST(request: Request) {
  if (!sameOriginPost(request, appOrigin())) return new Response('Forbidden', {status: 403});
  await (await serverSupabase()).auth.signOut();
  await clearWebSessionBinding();
  return NextResponse.redirect(new URL('/login', appOrigin()), {status: 303});
}
