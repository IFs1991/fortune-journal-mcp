-- Custom Access Token Hook: OAuth-client tokens get exactly the MCP audience; browser-session tokens are
-- unchanged; malformed client_id values are not upgraded. Runs as the role Supabase Auth uses. Rolled back.
BEGIN;
SET LOCAL ROLE supabase_auth_admin;
DO $$
DECLARE
  v_browser jsonb := '{"aud":"authenticated","role":"authenticated","sub":"11111111-1111-4111-8111-111111111111","session_id":"22222222-2222-4222-8222-222222222222"}';
  v_out jsonb;
BEGIN
  v_out := public.fj_access_token_hook(jsonb_build_object('user_id', v_browser->>'sub', 'claims',
    v_browser || '{"client_id":"c58523ed-4c1a-400a-88f4-bbc1e6927f29"}', 'authentication_method', 'oauth_provider/authorization_code'));
  IF v_out->'claims'->'aud' <> '"urn:fortune-journal:mcp"'::jsonb THEN
    RAISE EXCEPTION 'OAuth-client token did not get the MCP audience: %', v_out->'claims'->'aud';
  END IF;
  IF v_out->'claims'->>'client_id' IS NULL OR v_out->'claims'->>'sub' <> v_browser->>'sub' THEN
    RAISE EXCEPTION 'hook dropped or changed other claims';
  END IF;
  -- Refresh of an OAuth-client token: same rule.
  v_out := public.fj_access_token_hook(jsonb_build_object('claims',
    (v_browser - 'aud') || '{"aud":["authenticated"],"client_id":"x"}', 'authentication_method', 'token_refresh'));
  IF v_out->'claims'->'aud' <> '"urn:fortune-journal:mcp"'::jsonb THEN RAISE EXCEPTION 'refresh not restricted'; END IF;

  v_out := public.fj_access_token_hook(jsonb_build_object('claims', v_browser, 'authentication_method', 'oauth'));
  IF v_out->'claims' <> v_browser THEN RAISE EXCEPTION 'browser-session token was changed'; END IF;
  FOR v_out IN SELECT public.fj_access_token_hook(jsonb_build_object('claims', v_browser || x)) FROM
    (VALUES ('{"client_id":""}'::jsonb), ('{"client_id":123}'), ('{"client_id":null}')) AS t(x) LOOP
    IF v_out->'claims'->'aud' <> '"authenticated"'::jsonb THEN RAISE EXCEPTION 'malformed client_id upgraded'; END IF;
  END LOOP;
END $$;
RESET ROLE;

-- Client roles cannot call the hook (it would let them mint nothing, but the catalog rule is absolute).
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM public.fj_access_token_hook('{"claims":{}}');
  RAISE EXCEPTION 'authenticated executed the hook';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;
ROLLBACK;
