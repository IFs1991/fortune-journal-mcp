-- Privilege and catalog contract for EVERY object in the public schema (not a hard-coded list, so a new
-- table, view or function that forgets its revoke/RLS fails here). Read-only and rolled back, so it is also
-- safe to run against a reviewed Staging database with psql.
BEGIN;

DO $$
DECLARE
  rel record;
  fn record;
BEGIN
  FOR rel IN
    SELECT c.oid, c.relname, c.relkind, c.relrowsecurity, c.reloptions
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p')
  LOOP
    IF rel.relkind = 'r' AND NOT rel.relrowsecurity THEN
      RAISE EXCEPTION 'RLS disabled on table %', rel.relname;
    END IF;
    IF rel.relkind = 'v' AND NOT coalesce('security_invoker=true' = ANY (rel.reloptions), false) THEN
      RAISE EXCEPTION 'view % must use security_invoker', rel.relname;
    END IF;
    -- The Data API is not a product surface: customers reach data only through the app.
    IF has_any_column_privilege('anon', rel.oid, 'SELECT')
       OR has_any_column_privilege('authenticated', rel.oid, 'SELECT')
       OR has_table_privilege('anon', rel.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
       OR has_table_privilege('authenticated', rel.oid, 'INSERT, UPDATE, DELETE, TRUNCATE') THEN
      RAISE EXCEPTION 'client role has privileges on %', rel.relname;
    END IF;
    IF NOT has_table_privilege('service_role', rel.oid, 'SELECT') THEN
      RAISE EXCEPTION 'backend cannot read %', rel.relname;
    END IF;
  END LOOP;

  FOR fn IN
    SELECT p.oid, p.proname, p.oid::regprocedure AS signature, p.prosecdef, p.proconfig, p.prorettype = 'trigger'::regtype AS is_trigger
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    IF fn.prosecdef THEN
      RAISE EXCEPTION 'SECURITY DEFINER needs a dedicated review: %', fn.signature;
    END IF;
    IF NOT coalesce('search_path=""' = ANY (fn.proconfig), false) THEN
      RAISE EXCEPTION 'mutable search_path: %', fn.signature;
    END IF;
    IF has_function_privilege('anon', fn.oid, 'EXECUTE') OR has_function_privilege('authenticated', fn.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'client role can execute %', fn.signature;
    END IF;
    -- Supabase Auth (supabase_auth_admin) may run the token hook and nothing else in this schema.
    IF (fn.proname = 'fj_access_token_hook') <> has_function_privilege('supabase_auth_admin', fn.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'supabase_auth_admin EXECUTE on % is wrong', fn.signature;
    END IF;
    IF NOT fn.is_trigger AND NOT has_function_privilege('service_role', fn.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'backend cannot execute %', fn.signature;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r') = 0 THEN
    RAISE EXCEPTION 'no application tables found; the checks above would be vacuous';
  END IF;
END $$;

-- Behavioural confirmation of the catalog: client roles are refused at the privilege layer.
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  rel text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
  FOR rel IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v') LOOP
    BEGIN
      EXECUTE format('SELECT 1 FROM public.%I LIMIT 1', rel);
      RAISE EXCEPTION 'authenticated read %', rel;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  BEGIN
    PERFORM public.fj_record_calculation('11111111-1111-4111-8111-111111111111', gen_random_uuid(), repeat('f', 64),
      'calculate_numerology', 'x', current_date);
    RAISE EXCEPTION 'authenticated called fj_record_calculation';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.fj_access_status('11111111-1111-4111-8111-111111111111');
    RAISE EXCEPTION 'authenticated called fj_access_status';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM 1 FROM public.user_readings LIMIT 1;
    RAISE EXCEPTION 'anon read user_readings';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.fj_purge_expired();
    RAISE EXCEPTION 'anon purged';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

ROLLBACK;
