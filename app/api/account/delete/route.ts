import {NextResponse} from 'next/server';
import {deleteAccount} from '@/src/account';
import {readBoundedText} from '@/src/domain/security';
import {appOrigin} from '@/src/lib/env';
import {sameOriginPost} from '@/src/lib/urls';
import {clearWebSessionBinding, webSession} from '@/src/lib/web-session';

const FAILURES = {
  billing_open: [409, 'Cancel active or pending billing agreements before deleting your account.'],
  billing_unverifiable: [503, 'Cannot verify subscriptions'],
  suspend_failed: [503, 'Could not suspend access'],
  signout_failed: [503, 'Access suspended; session revocation needs attention.'],
  delete_failed: [503, 'Could not delete account'],
} as const;

export async function POST(request: Request) {
  if (!sameOriginPost(request, appOrigin())) return new Response('Forbidden', {status: 403});
  let form: URLSearchParams;
  try {
    form = new URLSearchParams(await readBoundedText(request, 4096));
  } catch {
    return new Response('Too large', {status: 413});
  }
  if (form.get('confirmation') !== 'DELETE_MY_ACCOUNT')
    return new Response('Confirmation required', {status: 400});
  const session = await webSession();
  if (!session) return new Response('Sign in required', {status: 401});
  const outcome = await deleteAccount(session.supabase, session.user.id);
  if (outcome !== 'deleted') {
    const [status, message] = FAILURES[outcome];
    return new Response(message, {status});
  }
  await clearWebSessionBinding();
  return NextResponse.redirect(new URL('/login', appOrigin()), {status: 303});
}
