const SENTINEL = 'https://next.invalid';

/**
 * Post-login destination. Only the consent page (with one well-formed authorization_id) or /login are possible
 * results, rebuilt from the parsed URL rather than echoed. Browsers drop TAB/CR/LF, treat '\' as '/' and decode
 * escapes when following a URL, so anything that is not plain printable ASCII is refused before parsing.
 */
export function safeNextPath(value: string | null | undefined): string {
  if (!value || value.length > 1024 || !/^\/[\x21-\x7e]*$/.test(value) || /^\/\/|\\|%5c/i.test(value))
    return '/login';
  let url: URL;
  try {
    url = new URL(value, SENTINEL);
  } catch {
    return '/login';
  }
  if (url.origin !== SENTINEL || url.pathname !== '/oauth/consent') return '/login';
  const ids = url.searchParams.getAll('authorization_id');
  const onlyId = [...url.searchParams.keys()].every((key) => key === 'authorization_id');
  return onlyId && ids.length === 1 && /^[A-Za-z0-9_-]{5,256}$/.test(ids[0])
    ? `/oauth/consent?authorization_id=${ids[0]}`
    : '/login';
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

/**
 * MCP Streamable HTTP transport rule: an Origin header that is present and not allowed is refused with 403
 * (DNS rebinding, browser pages). Server-side MCP hosts (ChatGPT, Claude) send no Origin and are unaffected.
 * The Host must be APP_ORIGIN's host, so a rebound or foreign name never reaches the handler.
 */
export function mcpRequestCheck(
  req: Request,
  appOrigin: string,
  allowedOrigins: readonly string[],
): 'ok' | 'forbidden_origin' | 'misdirected_host' {
  const origin = req.headers.get('origin');
  if (origin !== null && origin !== appOrigin && !allowedOrigins.includes(origin)) return 'forbidden_origin';
  const host = req.headers.get('host');
  return host !== null && host.toLowerCase() === new URL(appOrigin).host ? 'ok' : 'misdirected_host';
}
