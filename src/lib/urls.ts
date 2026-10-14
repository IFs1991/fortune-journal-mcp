/** Accept only root-relative paths without hostnames or URL scheme delimiters. */
export function safeNextPath(value: string | null | undefined): string {
  if (!value || !value.startsWith('/') || value.startsWith('//') || value.includes('\\') ||
      value.includes('\r') || value.includes('\n') || /%2f%2f/i.test(value)) return '/login';
  return value;
}

export function sameOriginPost(req: Request, expectedOrigin: string): boolean {
  return req.headers.get('origin') === expectedOrigin;
}
