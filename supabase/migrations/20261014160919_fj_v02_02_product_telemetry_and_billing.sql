BEGIN;
CREATE TABLE public.user_readings (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 request_id uuid NOT NULL,
 request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[a-f0-9]{64}$'),
 feature_key text NOT NULL CHECK (feature_key IN ('calculate_numerology','draw_tarot')),
 algorithm_version text NOT NULL CHECK (algorithm_version ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 target_date date NOT NULL,
 topic text CHECK (topic IN ('love','work','money','general')),
 tier_at_use text NOT NULL CHECK (tier_at_use IN ('free','trial','premium')),
 quota_bucket text NOT NULL CHECK (quota_bucket IN ('free_week','trial_day','premium_day')),
 quota_period_start date NOT NULL,
 remaining_after integer NOT NULL CHECK (remaining_after >= 0),
 calculated_at timestamptz NOT NULL DEFAULT now(),
 -- Calculation completed != user saw it != Google Sheets save succeeded.
 UNIQUE (user_id, request_id), UNIQUE (user_id, id)
);
CREATE INDEX user_readings_recent ON public.user_readings(user_id, calculated_at);
CREATE TABLE public.funnel_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 event_name text NOT NULL CHECK (event_name IN ('registration','analytics_enrolled','mcp_connected','reading_completed','journal_save_reported','life_log_reported','review_reported')),
 dedupe_key text NOT NULL CHECK (char_length(dedupe_key) BETWEEN 1 AND 160),
 occurred_at timestamptz NOT NULL,
 received_at timestamptz NOT NULL DEFAULT now(),
 source_channel text NOT NULL DEFAULT 'unknown' CHECK (source_channel IN ('threads','chatgpt','claude','direct','unknown')),
 source_evidence text NOT NULL DEFAULT 'unknown' CHECK (source_evidence IN ('signed_link','self_reported','registered_client','unknown')),
 observation text NOT NULL CHECK (observation IN ('server','self_reported')),
 post_id uuid REFERENCES public.fortune_posts(id) ON DELETE SET NULL,
 experiment_id text CHECK (experiment_id ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 reading_id uuid,
 UNIQUE (user_id, dedupe_key),
 FOREIGN KEY (user_id, reading_id) REFERENCES public.user_readings(user_id, id) ON DELETE CASCADE,
 CHECK ((event_name IN ('journal_save_reported','life_log_reported','review_reported') AND observation = 'self_reported')
 OR (event_name NOT IN ('journal_save_reported','life_log_reported','review_reported') AND observation = 'server'))
);
CREATE INDEX funnel_cohorts ON public.funnel_events(event_name, occurred_at, user_id);
CREATE INDEX funnel_attribution ON public.funnel_events(post_id, event_name) WHERE post_id IS NOT NULL;
CREATE TABLE public.reading_feedback (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 reading_id uuid NOT NULL,
 usefulness smallint NOT NULL CHECK (usefulness BETWEEN 1 AND 5),
 match_assessment text NOT NULL CHECK (match_assessment IN ('not_assessed','matched','mixed','not_matched','unclear')),
 followup_date date,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (user_id, reading_id),
 FOREIGN KEY (user_id, reading_id) REFERENCES public.user_readings(user_id, id) ON DELETE CASCADE
);
ALTER TABLE public.user_readings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.funnel_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reading_feedback ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_readings, public.funnel_events, public.reading_feedback FROM PUBLIC, anon, authenticated;
GRANT SELECT (id,user_id,request_id,feature_key,algorithm_version,target_date,topic,tier_at_use,calculated_at) ON public.user_readings TO authenticated;
GRANT SELECT ON public.reading_feedback TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.user_readings, public.funnel_events, public.reading_feedback TO service_role;
CREATE POLICY readings_owner_select ON public.user_readings FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY feedback_owner_select ON public.reading_feedback FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);

ALTER TABLE public.subscriptions
 ADD COLUMN verified_at timestamptz,
 ADD COLUMN provider_updated_at timestamptz,
 ADD COLUMN plan_key text CHECK (plan_key ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 ADD COLUMN amount_minor bigint CHECK (amount_minor >= 0),
 ADD COLUMN currency text CHECK (currency ~ '^[A-Z]{3}$'),
 ADD COLUMN currency_exponent smallint CHECK (currency_exponent BETWEEN 0 AND 6),
 ADD COLUMN interval_months smallint CHECK (interval_months BETWEEN 1 AND 12);
ALTER TABLE public.billing_events
 ADD COLUMN event_type text CHECK (event_type IN ('subscription_updated','payment_succeeded','payment_failed','subscription_canceled','refund_succeeded','chargeback')),
 ADD COLUMN provider_subscription_id text,
 ADD COLUMN occurred_at timestamptz,
 ADD COLUMN verified_at timestamptz,
 ADD COLUMN economic_key text CHECK (char_length(economic_key) BETWEEN 1 AND 160),
 ADD COLUMN original_payment_key text,
 ADD COLUMN amount_minor bigint CHECK (amount_minor >= 0),
 ADD COLUMN currency text CHECK (currency ~ '^[A-Z]{3}$'),
 ADD COLUMN currency_exponent smallint CHECK (currency_exponent BETWEEN 0 AND 6),
 ADD COLUMN billing_reason text CHECK (billing_reason IN ('initial','recurring','one_time','not_applicable')),
 ADD COLUMN plan_key text CHECK (plan_key ~ '^[A-Za-z0-9_.:-]{1,80}$'),
 ADD COLUMN error_code text CHECK (error_code ~ '^[A-Z0-9_]{1,80}$');
CREATE UNIQUE INDEX billing_economic_dedupe ON public.billing_events(provider, economic_key) WHERE economic_key IS NOT NULL;
CREATE INDEX billing_revenue_time ON public.billing_events(occurred_at, currency) WHERE processing_status = 'processed';
ALTER TABLE public.billing_events ADD CONSTRAINT normalized_financial_fields CHECK (
 event_type IS NULL OR event_type NOT IN ('payment_succeeded','refund_succeeded','chargeback') OR
 (economic_key IS NOT NULL AND amount_minor IS NOT NULL AND currency IS NOT NULL AND currency_exponent IS NOT NULL AND verified_at IS NOT NULL AND occurred_at IS NOT NULL));
COMMENT ON TABLE public.user_readings IS '90-day operational deduplication ledger, not reading text. Topic only with separate interest consent; keyed fingerprint is pseudonymous not anonymous.';
COMMENT ON TABLE public.reading_feedback IS 'Optional fixed-label feedback; never subjective accuracy proof, never free text';
COMMENT ON TABLE public.billing_events IS 'Normalized verified economic events. No raw webhook/card data. Cash collections are not MRR.';
COMMIT;
