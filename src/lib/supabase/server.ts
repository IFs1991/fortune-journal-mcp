import {cookies} from 'next/headers';
import {createServerClient} from '@supabase/ssr';
import {createClient} from '@supabase/supabase-js';
import {publicConfig} from '@/src/lib/env';
import {createMeteredFetch} from '@/src/lib/perf';

// Counts/times Auth and PostgREST calls for the current MCP request only (see src/lib/perf.ts).
const meteredFetch = createMeteredFetch((input, init) => fetch(input, init));

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

export function publicSupabase() {
  const {supabaseUrl, publishableKey} = publicConfig();
  return createClient(supabaseUrl, publishableKey, {
    auth: {persistSession: false, autoRefreshToken: false},
    global: {fetch: meteredFetch},
  });
}

/** Backend-only client; importing this function into client components is forbidden. */
export function adminSupabase() {
  const {supabaseUrl} = publicConfig();
  const secret = process.env.SUPABASE_SECRET_KEY;
  if (!secret) throw new Error('SUPABASE_SECRET_KEY is not configured');
  return createClient(supabaseUrl, secret, {
    auth: {persistSession: false, autoRefreshToken: false},
    global: {fetch: meteredFetch},
  });
}
