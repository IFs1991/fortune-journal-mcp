import {cookies} from 'next/headers';
import type {SupabaseClient, User} from '@supabase/supabase-js';
import {decodeJwtPayload, validateWebSessionClaims} from '@/src/domain/oauth-claims';
import {secureEqual, webSessionBinding} from '@/src/domain/security';
import {appOrigin, publicConfig} from '@/src/lib/env';
import {secret} from '@/src/lib/secrets';
import {serverSupabase} from '@/src/lib/supabase/server';

/**
 * The account web surface (/login, /oauth/consent, /api/account/*, /api/oauth/*) accepts only a browser session
 * that (1) Supabase Auth verifies now, (2) is a browser-session token (no OAuth client_id, aud='authenticated'
 * only, live session id), and (3) carries this app's HttpOnly binding cookie for that exact user and session,
 * which only /auth/callback issues. An MCP OAuth token placed into a Supabase cookie fails (2) and (3).
 * Anything else, including a configuration error, is treated as signed out (fail closed).
 */
export type WebSession = {supabase: SupabaseClient; user: User};

export function webBindingCookieName(): string {
  return appOrigin().startsWith('https://') ? '__Host-fj-web-session' : 'fj-web-session';
}

export async function webSession(): Promise<WebSession | null> {
  try {
    const supabase = await serverSupabase();
    // getSession() only reads (and refreshes) the cookie; the token is then verified by Supabase Auth below.
    const {
      data: {session},
    } = await supabase.auth.getSession();
    if (!session?.access_token) return null;
    const {data, error} = await supabase.auth.getUser(session.access_token);
    if (error || !data.user) return null;
    const payload = decodeJwtPayload(session.access_token);
    const claims =
      payload &&
      validateWebSessionClaims(payload, {
        issuer: `${publicConfig().supabaseUrl.replace(/\/$/, '')}/auth/v1`,
        userId: data.user.id,
        nowSeconds: Date.now() / 1000,
      });
    if (!claims) return null;
    const presented = (await cookies()).get(webBindingCookieName())?.value ?? '';
    const expected = webSessionBinding(secret('WEB_SESSION_HMAC_KEY'), data.user.id, claims.sessionId);
    return secureEqual(presented, expected) ? {supabase, user: data.user} : null;
  } catch {
    return null;
  }
}

/** Called by /auth/callback right after the browser's own PKCE code exchange created `accessToken`. */
export async function bindWebSession(userId: string, accessToken: string): Promise<boolean> {
  const payload = decodeJwtPayload(accessToken);
  const claims =
    payload &&
    validateWebSessionClaims(payload, {
      issuer: `${publicConfig().supabaseUrl.replace(/\/$/, '')}/auth/v1`,
      userId,
      nowSeconds: Date.now() / 1000,
    });
  if (!claims) return false;
  (await cookies()).set(
    webBindingCookieName(),
    webSessionBinding(secret('WEB_SESSION_HMAC_KEY'), userId, claims.sessionId),
    {
      httpOnly: true,
      secure: appOrigin().startsWith('https://'),
      sameSite: 'lax',
      path: '/',
      maxAge: 400 * 86_400,
    },
  );
  return true;
}

export async function clearWebSessionBinding(): Promise<void> {
  (await cookies()).delete(webBindingCookieName());
}
