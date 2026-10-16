import {NextResponse} from 'next/server';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {serverSupabase, adminSupabase} from '@/src/lib/supabase/server';

export async function POST(request: Request) {
  if (!sameOriginPost(request, appOrigin())) return new Response('Forbidden', {status: 403});
  const form = await request.formData();
  if (form.get('confirmation') !== 'DELETE_MY_ACCOUNT')
    return new Response('Confirmation required', {status: 400});
  const supabase = await serverSupabase();
  const {
    data: {user},
  } = await supabase.auth.getUser();
  if (!user) return new Response('Sign in required', {status: 401});
  const admin = adminSupabase();
  const {data: subscriptions, error: fetchError} = await admin
    .from('subscriptions')
    .select('status')
    .eq('user_id', user.id);
  if (fetchError) return new Response('Cannot verify subscriptions', {status: 503});
  if (
    (subscriptions ?? []).some((s) =>
      ['active', 'trialing', 'past_due', 'incomplete', 'unpaid'].includes(s.status),
    )
  ) {
    return new Response('Cancel active or pending billing agreements before deleting your account.', {
      status: 409,
    });
  }
  const {error: suspensionError} = await admin
    .from('user_access')
    .upsert({user_id: user.id, suspended_at: new Date().toISOString()}, {onConflict: 'user_id'});
  if (suspensionError) return new Response('Could not suspend access', {status: 503});
  const {error: signoutError} = await supabase.auth.signOut({scope: 'global'});
  if (signoutError)
    return new Response('Access suspended; session revocation needs attention.', {status: 503});
  // Each MCP request also calls Auth.getUser; a deleted account is rejected even with an unexpired JWT.
  // FK CASCADE deletes entitlement/usage/subscription rows; billing_events user_id is SET NULL.
  const {error} = await admin.auth.admin.deleteUser(user.id);
  if (error) return new Response('Could not delete account', {status: 503});
  await supabase.auth.signOut();
  return NextResponse.redirect(new URL('/login', appOrigin()), {status: 303});
}
