import type { AuthInfo } from '@modelcontextprotocol/server';
import { publicSupabase } from '@/src/lib/supabase/server';
import { publicConfig } from '@/src/lib/env';
import { decodeJwtPayload, validateMcpAccessClaims } from '@/src/domain/oauth-claims';

/**
 * Verify every bearer token with Supabase Auth (signature, session and account liveness),
 * then require claims bound to this project's issuer, the same user and an OAuth client_id.
 * Google web sign-in cookies/session JWTs (no client_id) are not sufficient to call /api/mcp.
 * Supabase OAuth JWTs use aud='authenticated' rather than a resource-specific aud;
 * the Supabase project must be dedicated to this app (see docs/SECURITY.md).
 */
export async function verifyOAuthBearer(_req: Request, bearerToken?: string): Promise<AuthInfo | undefined> {
  if (!bearerToken || bearerToken.length > 16_384) return undefined;
  const payload = decodeJwtPayload(bearerToken);
  if (!payload || typeof payload.client_id !== 'string') return undefined; // cheap reject before a network call
  try {
    const {data,error} = await publicSupabase().auth.getUser(bearerToken);
    if (error || !data.user) return undefined;
    const {supabaseUrl} = publicConfig();
    const claims = validateMcpAccessClaims(payload, {
      issuer: `${supabaseUrl.replace(/\/$/, '')}/auth/v1`, userId: data.user.id, nowSeconds: Date.now() / 1000,
    });
    if (!claims) return undefined;
    return {token: bearerToken, scopes: [], clientId: claims.clientId, expiresAt: claims.expiresAt, extra: {userId: data.user.id}};
  } catch {
    return undefined;
  }
}

export function getAuthenticatedUserId(context: { http?: { authInfo?: AuthInfo } } ): string | null {
  const userId = context.http?.authInfo?.extra?.userId;
  return typeof userId === 'string' && /^[0-9a-f-]{36}$/i.test(userId) ? userId : null;
}
