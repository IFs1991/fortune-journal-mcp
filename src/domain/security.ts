import {createHash, createHmac, timingSafeEqual} from 'node:crypto';
export function sha256(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}
export function secureEqual(a: string, b: string): boolean {
  const x = Buffer.from(a),
    y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}
export function requireSecret(secret: string | undefined): string {
  if (!secret || secret.length < 32 || /REPLACE|YOUR[_-]/i.test(secret))
    throw new Error('SECRET_NOT_CONFIGURED');
  return secret;
}
export function requestFingerprint(
  secret: string,
  userId: string,
  requestId: string,
  feature: string,
  orderedInput: unknown[],
): string {
  return createHmac('sha256', requireSecret(secret))
    .update(JSON.stringify(['fj-request-v2', userId, requestId, feature, ...orderedInput]))
    .digest('hex');
}
export function signOps(
  secret: string,
  method: string,
  path: string,
  timestamp: string,
  body: string,
): string {
  return createHmac('sha256', requireSecret(secret))
    .update(`${timestamp}\n${method.toUpperCase()}\n${path}\n${sha256(body)}`)
    .digest('hex');
}
export function verifyOps(
  secret: string | undefined,
  method: string,
  path: string,
  timestamp: string | null,
  signature: string | null,
  body: string,
  nowSeconds = Date.now() / 1000,
): boolean {
  if (!timestamp || !/^\d{10}$/.test(timestamp) || !signature || !/^[a-f0-9]{64}$/.test(signature))
    return false;
  if (Math.abs(nowSeconds - Number(timestamp)) > 300) return false;
  try {
    return secureEqual(signOps(requireSecret(secret), method, path, timestamp, body), signature);
  } catch {
    return false;
  }
}
/**
 * Proof that a Supabase session was created by this app's own Google sign-in callback (/auth/callback), stored
 * in an HttpOnly cookie. An OAuth client holding the user's MCP tokens can rebuild a Supabase cookie but cannot
 * mint this value, so it cannot reach the account APIs. Session ids survive token refresh; a new sign-in rebinds.
 */
export function webSessionBinding(secret: string, userId: string, sessionId: string): string {
  return createHmac('sha256', requireSecret(secret))
    .update(`fj-web-session-v1\n${userId}\n${sessionId}`)
    .digest('hex');
}
export function issueReferral(
  secret: string,
  postId: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): string {
  if (!/^[a-f0-9-]{36}$/i.test(postId)) throw new Error('INVALID_POST_ID');
  const data = Buffer.from(JSON.stringify({postId, exp: nowSeconds + 7 * 86400})).toString('base64url');
  return `${data}.${createHmac('sha256', requireSecret(secret)).update(`fj-ref-v1:${data}`).digest('hex')}`;
}
export function readReferral(
  secret: string | undefined,
  token: string | undefined,
  nowSeconds = Date.now() / 1000,
): {postId: string} | null {
  try {
    if (!token || token.length > 1024) return null;
    const parts = token.split('.');
    if (parts.length !== 2) return null;
    const [data, sig] = parts;
    const actual = createHmac('sha256', requireSecret(secret)).update(`fj-ref-v1:${data}`).digest('hex');
    if (!secureEqual(sig, actual)) return null;
    const value = JSON.parse(Buffer.from(data, 'base64url').toString());
    if (
      typeof value.exp !== 'number' ||
      value.exp < nowSeconds ||
      value.exp > nowSeconds + 7 * 86400 + 300 ||
      typeof value.postId !== 'string' ||
      !/^[a-f0-9-]{36}$/i.test(value.postId)
    )
      return null;
    return {postId: value.postId};
  } catch {
    return null;
  }
}
/** Bounded streaming body read: Content-Length alone is attacker-controlled. */
export async function readBoundedText(request: Request, limit = 65536): Promise<string> {
  const reader = request.body?.getReader();
  if (!reader) return '';
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const part = await reader.read();
      if (part.done) break;
      size += part.value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new Error('BODY_TOO_LARGE');
      }
      chunks.push(part.value);
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks).toString('utf8');
}
