/**
 * Runtime configuration shared by server and browser code (keep it free of Node-only imports).
 * Secrets are read through src/lib/secrets.ts. Every variable is documented in .env.example.
 */
export function publicConfig() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!supabaseUrl || !publishableKey) throw new Error('Supabase public environment is not configured');
  return {supabaseUrl, publishableKey};
}

export function appOrigin(): string {
  const origin = process.env.APP_ORIGIN;
  const valid = !!origin && (/^https:\/\/[^/]+$/.test(origin) || /^http:\/\/localhost:\d+$/.test(origin));
  if (!valid) throw new Error('APP_ORIGIN must be an HTTPS origin, or localhost for development');
  return origin;
}

/** Feature switches. All default to off; see .env.example. */
type Flag =
  'PRODUCT_ANALYTICS_ENABLED' | 'OPERATIONS_ENABLED' | 'THREADS_INSIGHTS_ENABLED' | 'THREADS_PUBLISH_ENABLED';
export function isEnabled(flag: Flag): boolean {
  return process.env[flag] === 'true';
}

/**
 * Platform of an operator-verified OAuth client (MCP_CLIENT_NAMES_JSON). Dynamically registered clients choose
 * their own name, so anything not listed is 'unknown'. The platform is not evidence of how a user found us.
 */
export function clientPlatform(clientId: string | undefined): 'chatgpt' | 'claude' | 'unknown' {
  if (!clientId) return 'unknown';
  try {
    const mapping: unknown = JSON.parse(process.env.MCP_CLIENT_NAMES_JSON ?? '{}');
    const value =
      mapping && typeof mapping === 'object' ? (mapping as Record<string, unknown>)[clientId] : undefined;
    return value === 'chatgpt' || value === 'claude' ? value : 'unknown';
  } catch {
    return 'unknown';
  }
}
