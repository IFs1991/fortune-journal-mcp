import {cookies} from 'next/headers';
import {createServerClient} from '@supabase/ssr';
import {createClient, type SupabaseClient} from '@supabase/supabase-js';
import {publicConfig} from '@/src/lib/env';
import {createMeteredFetch} from '@/src/lib/perf';

// Counts/times Auth and PostgREST calls for the current MCP request only (see src/lib/perf.ts).
const meteredFetch = createMeteredFetch((input, init) => fetch(input, init));
const stateless = {persistSession: false, autoRefreshToken: false};

/** Browser-session client for pages and route handlers (reads and refreshes the Supabase Auth cookies). */
export async function serverSupabase() {
  const cookieStore = await cookies();
  const {supabaseUrl, publishableKey} = publicConfig();
  return createServerClient(supabaseUrl, publishableKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (items) => {
        try {
          items.forEach(({name, value, options}) => cookieStore.set(name, value, options));
        } catch {
          // Server Components cannot set cookies. Route handlers and OAuth callbacks can.
        }
      },
    },
  });
}

// Stateless clients hold no user state, so one instance per server process is reused across requests.
let publicClient: SupabaseClient | undefined;
let adminClient: SupabaseClient | undefined;

/** Publishable-key client, used to verify MCP bearer tokens with Supabase Auth. */
export function publicSupabase(): SupabaseClient {
  const {supabaseUrl, publishableKey} = publicConfig();
  publicClient ??= createClient(supabaseUrl, publishableKey, {
    auth: stateless,
    global: {fetch: meteredFetch},
  });
  return publicClient;
}

/**
 * service_role client: bypasses RLS. Server code only; every user id it receives must come from a verified
 * Supabase Auth user, never from request input.
 */
export function adminSupabase(): SupabaseClient {
  const {supabaseUrl} = publicConfig();
  const secretKey = process.env.SUPABASE_SECRET_KEY;
  if (!secretKey) throw new Error('SUPABASE_SECRET_KEY is not configured');
  adminClient ??= createClient(supabaseUrl, secretKey, {auth: stateless, global: {fetch: meteredFetch}});
  return adminClient;
}
