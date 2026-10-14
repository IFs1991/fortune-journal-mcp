-- Additive v0.2 template. Generate a real timestamped migration with scripts/prepare-migrations.mjs.
-- No changes to the historical v0.1 migration. Run only against a reviewed target.
BEGIN;
ALTER TABLE public.user_access ALTER COLUMN trial_started_at DROP NOT NULL;
ALTER TABLE public.user_access ALTER COLUMN trial_started_at DROP DEFAULT;
ALTER TABLE public.user_access ALTER COLUMN trial_ends_at DROP NOT NULL;
ALTER TABLE public.user_access ALTER COLUMN trial_ends_at DROP DEFAULT;
ALTER TABLE public.user_access ADD CONSTRAINT trial_pair_valid CHECK
 ((trial_started_at IS NULL AND trial_ends_at IS NULL) OR
  (trial_started_at IS NOT NULL AND trial_ends_at IS NOT NULL));
ALTER TABLE public.user_access
 ADD COLUMN analytics_consent_at timestamptz,
 ADD COLUMN interest_consent_at timestamptz,
 ADD COLUMN consent_version text,
 ADD COLUMN consent_updated_at timestamptz,
 ADD COLUMN analytics_revoked_at timestamptz;
ALTER TABLE public.user_access ADD CONSTRAINT interest_requires_analytics
 CHECK (interest_consent_at IS NULL OR analytics_consent_at IS NOT NULL);

CREATE TABLE public.fortune_posts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 account_key text NOT NULL CHECK (account_key ~ '^[A-Za-z0-9_:-]{1,100}$'),
 platform text NOT NULL DEFAULT 'threads' CHECK (platform = 'threads'),
 external_post_id text CHECK (external_post_id ~ '^[0-9]{1,80}$'),
 container_id text CHECK (container_id ~ '^[0-9]{1,80}$'),
 body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 10000),
 body_sha256 text NOT NULL CHECK (body_sha256 ~ '^[a-f0-9]{64}$'),
 body_length integer GENERATED ALWAYS AS (char_length(body)) STORED,
 topic text NOT NULL DEFAULT 'unclassified' CHECK (topic IN ('love','work','money','general','unclassified')),
 method text NOT NULL DEFAULT 'unclassified' CHECK (method IN ('tarot','numerology','mixed','unclassified')),
 tone text NOT NULL DEFAULT 'unclassified' CHECK (tone IN ('empathetic','assertive','question','unclassified')),
 zodiac text CHECK (zodiac IN ('aries','taurus','gemini','cancer','leo','virgo','libra','scorpio','sagittarius','capricorn','aquarius','pisces')),
 language text NOT NULL DEFAULT 'und' CHECK (language ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$'),
 hook_text text CHECK (char_length(hook_text) <= 240),
 cta_key text NOT NULL DEFAULT 'none' CHECK (cta_key IN ('none','reflect','save','reply','visit_profile')),
 prompt_version text CHECK (prompt_version ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 experiment_id text CHECK (experiment_id ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 variant_key text CHECK (variant_key ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','publishing','publish_unknown','published','failed','archived')),
 scheduled_at timestamptz,
 published_at timestamptz,
 approved_at timestamptz,
 approved_body_sha256 text CHECK (approved_body_sha256 ~ '^[a-f0-9]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((status <> 'published') OR (external_post_id IS NOT NULL AND published_at IS NOT NULL)),
 CHECK ((status NOT IN ('approved','publishing')) OR (approved_at IS NOT NULL AND approved_body_sha256 = body_sha256)),
 UNIQUE (account_key, external_post_id)
);
CREATE INDEX fortune_posts_due ON public.fortune_posts(scheduled_at) WHERE status = 'approved';
CREATE INDEX fortune_posts_experiment ON public.fortune_posts(experiment_id, variant_key, published_at);

CREATE TABLE public.automation_runs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 task text NOT NULL CHECK (task IN ('publish_post','collect_post_metrics','collect_account_metrics','import_posts','draft_post','weekly_analysis','purge','billing_reconcile')),
 idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 1 AND 240),
 post_id uuid REFERENCES public.fortune_posts(id) ON DELETE SET NULL,
 status text NOT NULL DEFAULT 'running' CHECK (status IN ('running','succeeded','failed','unknown')),
 actor_kind text NOT NULL CHECK (actor_kind IN ('owner_agent','server_cron','operator','external_report')),
 started_at timestamptz NOT NULL DEFAULT now(),
 finished_at timestamptz,
 lease_expires_at timestamptz NOT NULL DEFAULT (now() + interval '2 minutes'),
 attempts integer NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 100),
 duration_ms bigint CHECK (duration_ms >= 0),
 model text CHECK (char_length(model) <= 120),
 input_tokens bigint CHECK (input_tokens >= 0),
 output_tokens bigint CHECK (output_tokens >= 0),
 estimated_cost numeric(20,8) CHECK (estimated_cost >= 0),
 cost_currency text CHECK (cost_currency ~ '^[A-Z]{3}$'),
 cost_source text NOT NULL DEFAULT 'unobserved' CHECK (cost_source IN ('unobserved','provider_reported','external_reported','estimate','not_applicable')),
 error_code text CHECK (error_code ~ '^[A-Z0-9_]{1,80}$'),
 CHECK ((estimated_cost IS NULL AND cost_currency IS NULL) OR (estimated_cost IS NOT NULL AND cost_currency IS NOT NULL)),
 CHECK (cost_source NOT IN ('unobserved','not_applicable') OR (estimated_cost IS NULL AND input_tokens IS NULL AND output_tokens IS NULL)),
 CHECK ((status = 'running' AND finished_at IS NULL) OR (status <> 'running' AND finished_at IS NOT NULL)),
 UNIQUE (task, idempotency_key)
);
CREATE INDEX automation_runs_recent ON public.automation_runs(started_at DESC);

CREATE TABLE public.post_metric_snapshots (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 post_id uuid NOT NULL REFERENCES public.fortune_posts(id) ON DELETE CASCADE,
 run_id uuid REFERENCES public.automation_runs(id) ON DELETE SET NULL,
 collected_at timestamptz NOT NULL,
 target_age_hours smallint CHECK (target_age_hours IN (24,72,168)),
 snapshot_kind text NOT NULL CHECK (snapshot_kind IN ('scheduled','manual','backfill_now')),
 metric_period text NOT NULL DEFAULT 'lifetime' CHECK (metric_period = 'lifetime'),
 api_version text NOT NULL CHECK (api_version ~ '^v[0-9]+\.[0-9]+$'),
 views bigint CHECK (views >= 0), likes bigint CHECK (likes >= 0),
 replies bigint CHECK (replies >= 0), reposts bigint CHECK (reposts >= 0),
 quotes bigint CHECK (quotes >= 0), shares bigint CHECK (shares >= 0),
 CHECK ((snapshot_kind = 'scheduled' AND target_age_hours IS NOT NULL) OR (snapshot_kind <> 'scheduled' AND target_age_hours IS NULL)),
 UNIQUE (run_id, post_id)
);
CREATE INDEX post_snapshots_observation ON public.post_metric_snapshots(post_id, collected_at);
CREATE INDEX post_snapshots_target ON public.post_metric_snapshots(post_id, target_age_hours) WHERE target_age_hours IS NOT NULL;

-- LONG form is intentional: follower count is a stock, whereas period insights are flows.
CREATE TABLE public.account_metric_snapshots (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 account_key text NOT NULL CHECK (account_key ~ '^[A-Za-z0-9_:-]{1,100}$'),
 run_id uuid REFERENCES public.automation_runs(id) ON DELETE SET NULL,
 capture_key uuid NOT NULL,
 collected_at timestamptz NOT NULL,
 metric_name text NOT NULL CHECK (metric_name IN ('views','likes','replies','reposts','quotes','followers_count')),
 metric_value bigint CHECK (metric_value >= 0),
 period_kind text NOT NULL CHECK (period_kind IN ('point_in_time','day','range')),
 period_start timestamptz,
 period_end timestamptz,
 api_version text NOT NULL CHECK (api_version ~ '^v[0-9]+\.[0-9]+$'),
 CHECK ((metric_name = 'followers_count' AND period_kind = 'point_in_time' AND period_start IS NULL AND period_end IS NULL)
 OR (metric_name <> 'followers_count' AND period_kind IN ('day','range') AND period_start IS NOT NULL AND period_end > period_start)),
 CHECK (run_id IS NULL OR run_id = capture_key),
 UNIQUE NULLS NOT DISTINCT (capture_key, account_key, metric_name, period_kind, period_start, period_end)
);
CREATE INDEX account_snapshots_observation ON public.account_metric_snapshots(account_key, metric_name, collected_at);

ALTER TABLE public.fortune_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_metric_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_metric_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fortune_posts, public.automation_runs, public.post_metric_snapshots, public.account_metric_snapshots FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fortune_posts, public.automation_runs, public.post_metric_snapshots, public.account_metric_snapshots TO service_role;
-- No consumer-facing policies on any marketing/operations table.

CREATE FUNCTION public.fj_guard_post_edit() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF OLD.status IN ('publishing','publish_unknown','published') AND
    (NEW.body IS DISTINCT FROM OLD.body OR NEW.body_sha256 IS DISTINCT FROM OLD.body_sha256) THEN
  RAISE EXCEPTION 'PUBLISHED_CONTENT_IMMUTABLE';
 END IF;
 IF NEW.body IS DISTINCT FROM OLD.body OR NEW.body_sha256 IS DISTINCT FROM OLD.body_sha256 THEN
  NEW.status := 'draft'; NEW.approved_at := NULL; NEW.approved_body_sha256 := NULL;
 END IF;
 NEW.updated_at := now();
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.fj_guard_post_edit() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER fj_post_edit BEFORE UPDATE ON public.fortune_posts FOR EACH ROW EXECUTE FUNCTION public.fj_guard_post_edit();
COMMENT ON TABLE public.fortune_posts IS 'Owned public marketing content, never customer journal content';
COMMENT ON TABLE public.account_metric_snapshots IS 'One metric and interval per row; never sum follower stocks or overlapping ranges';
COMMIT;
