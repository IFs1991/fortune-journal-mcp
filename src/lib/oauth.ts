import type { AuthInfo } from '@modelcontextprotocol/server';
import { publicSupabase } from '@/src/lib/supabase/server';
import { publicConfig } from '@/src/lib/env';

/**
 * Verify every bearer token with Supabase Auth, then require an OAuth client_id claim.
 * Google web sign-in cookies are not sufficient to call /api/mcp.
 * Supabase OAuth JWTs currently use aud='authenticated' rather than a resource-specific aud;
 * dedicate a Supabase project to this app and test resource-indicator compatibility before launch.
 */
export async function verifyOAuthBearer(_req: Request, bearerToken?: string): Promise<AuthInfo | undefined> {
  if (!bearerToken || bearerToken.length > 16_384) return undefined;
  try {
    const supabase = publicSupabase();
    const {data,error} = await supabase.auth.getUser(bearerToken);
    if (error || !data.user) return undefined;
    const parts = bearerToken.split('.');
    if (parts.length !== 3) return undefined;
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')) as Record<string, unknown>;
    const {supabaseUrl} = publicConfig();
    const iss = `${supabaseUrl.replace(/\/$/, '')}/auth/v1`;
    const aud = payload.aud;
    const goodAudience = aud === 'authenticated' || (Array.isArray(aud) && aud.includes('authenticated'));
    if (payload.iss !== iss || !goodAudience || payload.sub !== data.user.id ||
        payload.role !== 'authenticated' || typeof payload.client_id !== 'string' ||
        !payload.client_id || typeof payload.exp !== 'number' || payload.exp * 1000 <= Date.now()) {
      return undefined;
    }
    return {
      token: bearerToken,
      scopes: [],
      clientId: payload.client_id,
      extra: {userId: data.user.id},
    };
  } catch {
    return undefined;
  }
}

export function getAuthenticatedUserId(context: { http?: { authInfo?: AuthInfo } } ): string | null {
  const userId = context.http?.authInfo?.extra?.userId;
  return typeof userId === 'string' && /^[0-9a-f-]{36}$/i.test(userId) ? userId : null;
}
