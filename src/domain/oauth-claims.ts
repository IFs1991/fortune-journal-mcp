/** Pure claim checks for MCP bearer tokens. Signature/liveness is verified separately by Supabase Auth (getUser). */
export type McpClaimCheck = {issuer: string; userId: string; nowSeconds: number};

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

/**
 * Supabase OAuth 2.1 access tokens carry client_id; browser-session tokens do not.
 * Supabase currently issues aud='authenticated' (no RFC 8707 resource-specific aud), so the
 * project must be dedicated to this app. Returns null for anything not bound to this user+issuer.
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
 * issuer, browser-session token) without a Supabase Auth round trip; passing it never authenticates anything.
 */
export function precheckMcpAccessClaims(
  payload: Record<string, unknown>,
  check: Omit<McpClaimCheck, 'userId'>,
): boolean {
  const issuer = check.issuer.replace(/\/+$/, '');
  const aud = payload.aud;
  const goodAudience = aud === 'authenticated' || (Array.isArray(aud) && aud.includes('authenticated'));
  if (payload.iss !== issuer || !goodAudience || payload.role !== 'authenticated') return false;
  if (typeof payload.sub !== 'string' || !/^[0-9a-f-]{36}$/i.test(payload.sub)) return false;
  if (typeof payload.client_id !== 'string' || !payload.client_id || payload.client_id.length > 256)
    return false;
  return typeof payload.exp === 'number' && Number.isFinite(payload.exp) && payload.exp > check.nowSeconds;
}
