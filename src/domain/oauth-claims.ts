/** Pure claim checks for MCP bearer tokens. Signature/liveness is verified separately by Supabase Auth (getUser). */
export type McpClaimCheck = {issuer: string; userId: string; nowSeconds: number};

/**
 * Audience of every access token this project issues to an OAuth client. Supabase Auth always issues
 * aud='authenticated' and ignores the RFC 8707 `resource` parameter, so the Custom Access Token Hook
 * (public.fj_access_token_hook in the baseline migration) replaces aud with this value whenever the token carries
 * a client_id. Browser-session tokens keep aud='authenticated'. Keep both copies identical.
 */
export const MCP_TOKEN_AUDIENCE = 'urn:fortune-journal:mcp';

export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split('.');
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const value: unknown = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return value && typeof value === 'object' && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

const audiences = (payload: Record<string, unknown>): unknown[] => [payload.aud].flat();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function commonClaims(payload: Record<string, unknown>, issuer: string, nowSeconds: number): boolean {
  return (
    payload.iss === issuer.replace(/\/+$/, '') &&
    payload.role === 'authenticated' &&
    typeof payload.sub === 'string' &&
    UUID.test(payload.sub) &&
    typeof payload.exp === 'number' &&
    Number.isFinite(payload.exp) &&
    payload.exp > nowSeconds
  );
}

/**
 * Supabase OAuth 2.1 access tokens carry client_id and, through the hook, aud=MCP_TOKEN_AUDIENCE only.
 * Returns null for anything not bound to this user, issuer and audience.
 */
export function validateMcpAccessClaims(
  payload: Record<string, unknown>,
  check: McpClaimCheck,
): {clientId: string; expiresAt: number} | null {
  if (!precheckMcpAccessClaims(payload, check) || payload.sub !== check.userId) return null;
  return {clientId: payload.client_id as string, expiresAt: payload.exp as number};
}

/**
 * Same claim rules minus the user binding, on the UNVERIFIED payload. Used only to reject (expired, foreign
 * issuer, wrong audience, browser-session token) without a Supabase Auth round trip; passing it never
 * authenticates anything.
 */
export function precheckMcpAccessClaims(
  payload: Record<string, unknown>,
  check: Omit<McpClaimCheck, 'userId'>,
): boolean {
  // Exactly our audience: a token that is also valid for another audience is not a token for this resource.
  const aud = audiences(payload);
  if (aud.length !== 1 || aud[0] !== MCP_TOKEN_AUDIENCE) return false;
  if (!commonClaims(payload, check.issuer, check.nowSeconds)) return false;
  return typeof payload.client_id === 'string' && !!payload.client_id && payload.client_id.length <= 256;
}

/**
 * Browser-session tokens for the account web pages and APIs: issued by Supabase Auth to the user's own browser
 * (no client_id, aud='authenticated' only), bound to a live session id. Any OAuth-client token is refused here,
 * whatever else it claims. Run on the payload of the exact token Supabase Auth just verified.
 */
export function validateWebSessionClaims(
  payload: Record<string, unknown>,
  check: McpClaimCheck,
): {sessionId: string} | null {
  const aud = audiences(payload);
  if (aud.length !== 1 || aud[0] !== 'authenticated') return null;
  if (!commonClaims(payload, check.issuer, check.nowSeconds) || payload.sub !== check.userId) return null;
  if ('client_id' in payload || payload.is_anonymous === true) return null;
  if (typeof payload.session_id !== 'string' || !UUID.test(payload.session_id)) return null;
  return {sessionId: payload.session_id};
}
