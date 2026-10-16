export function publicConfig() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!supabaseUrl || !publishableKey) throw new Error('Supabase public environment is not configured');
  return {supabaseUrl, publishableKey};
}

export function appOrigin(): string {
  const origin = process.env.APP_ORIGIN;
  if (!origin || (!/^https:\/\/[^/]+$/.test(origin) && !/^http:\/\/localhost:\d+$/.test(origin))) {
    throw new Error('APP_ORIGIN must be an HTTPS origin, or localhost for development');
  }
  return origin;
}

export function billingNotConfigured(): boolean {
  return true; // Fail closed until a signed, approved provider adapter is implemented.
}
