'use client';
import { createBrowserClient } from '@supabase/ssr';
import { publicConfig } from '@/src/lib/env';

export function browserSupabase() {
  const {supabaseUrl,publishableKey} = publicConfig();
  return createBrowserClient(supabaseUrl, publishableKey);
}
