import {NextResponse} from 'next/server';
import {serverSupabase, adminSupabase} from '@/src/lib/supabase/server';
import {sameOriginPost} from '@/src/lib/urls';
import {appOrigin} from '@/src/lib/env';
import {PRIVACY_VERSION} from '@/src/lib/telemetry';
import {readReferral, readBoundedText} from '@/src/domain/security';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function POST(request: Request) {
  if (!sameOriginPost(request, appOrigin())) return new Response('Forbidden', {status: 403});
  const {
    data: {user},
  } = await (await serverSupabase()).auth.getUser();
  if (!user) return new Response('Sign in required', {status: 401});
  let body: string;
  try {
    body = await readBoundedText(request, 8192);
  } catch {
    return new Response('Too large', {status: 413});
  }
  const form = new URLSearchParams(body),
    analytics = form.get('analytics') === 'yes',
    interests = form.get('interests') === 'yes';
  if (analytics && process.env.PRODUCT_ANALYTICS_ENABLED !== 'true')
    return new Response('Optional analytics is disabled', {status: 503});
  const db = adminSupabase();
  const {error} = await db.rpc('fj_set_privacy', {
    p_user_id: user.id,
    p_analytics: analytics,
    p_interests: analytics && interests,
    p_version: PRIVACY_VERSION,
    // Registration time comes from the verified Supabase Auth user; service_role cannot read auth.users (migration 06).
    p_registered_at: user.created_at ?? null,
  });
  if (error) return new Response('Could not update preferences', {status: 503});
  if (analytics) {
    const ref = readReferral(process.env.ATTRIBUTION_HMAC_KEY, form.get('ref') ?? undefined);
    const source = form.get('source');
    const result = ref
      ? await db.rpc('fj_set_attribution', {
          p_user_id: user.id,
          p_channel: 'threads',
          p_evidence: 'signed_link',
          p_post_id: ref.postId,
        })
      : ['threads', 'chatgpt', 'claude', 'direct'].includes(source ?? '')
        ? await db.rpc('fj_set_attribution', {
            p_user_id: user.id,
            p_channel: source,
            p_evidence: 'self_reported',
          })
        : null;
    if (result?.error) console.warn('FJ_ATTRIBUTION_NOT_RECORDED');
  }
  return NextResponse.redirect(new URL('/login?preferences=saved', appOrigin()), {status: 303});
}
