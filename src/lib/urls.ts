/** Accept only root-relative paths without hostnames or URL scheme delimiters. */
export function safeNextPath(value: string | null | undefined): string {
  if (
    !value ||
    !value.startsWith('/') ||
    value.startsWith('//') ||
    value.includes('\\') ||
    value.includes('\r') ||
    value.includes('\n') ||
    /%2f%2f/i.test(value)
  )
    return '/login';
  return value;
}

/**
 * Cookie-authenticated state change submitted by one of this site's own forms: exact Origin, same-origin fetch
 * metadata when the browser sends it, and a urlencoded form body (no JSON/text that a cross-site fetch could
 * send without a preflight). Missing Origin fails closed.
 */
export function sameOriginPost(req: Request, expectedOrigin: string): boolean {
  if (req.method !== 'POST' || req.headers.get('origin') !== expectedOrigin) return false;
  const site = req.headers.get('sec-fetch-site');
  if (site !== null && site !== 'same-origin') return false;
  return /^application\/x-www-form-urlencoded\s*(;|$)/i.test(req.headers.get('content-type') ?? '');
}

/** Cookie-authenticated GET (data export): a link on this site or a typed URL, never a cross-site request. */
export function sameOriginNavigation(req: Request, expectedOrigin: string): boolean {
  const site = req.headers.get('sec-fetch-site');
  if (site !== null && site !== 'same-origin' && site !== 'none') return false;
  const origin = req.headers.get('origin');
  return origin === null || origin === expectedOrigin;
}
