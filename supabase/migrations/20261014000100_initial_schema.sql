-- Fortune Journal v0.1. User data is stored in the user's Google Sheets, not here.
-- This migration is a reviewed bootstrap draft; apply first to a disposable Supabase project.
-- DO NOT copy Tiramisu Works tables, policies or service keys.

create table public.user_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  trial_started_at timestamptz not null default now(),
  trial_ends_at timestamptz not null default (now() + interval '14 days'),
  suspended_at timestamptz,
  created_at timestamptz not null default now(),
  constraint trial_window_valid check (trial_ends_at >= trial_started_at)
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  provider_customer_id text not null,
  provider_subscription_id text not null,
  status text not null check (status in ('incomplete','trialing','active','past_due','canceled','unpaid','expired')),
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_subscription_id)
);
create index subscriptions_by_user on public.subscriptions(user_id);

create table public.usage_counters (
  user_id uuid not null references auth.users(id) on delete cascade,
  feature_key text not null check (feature_key in ('calculate_numerology','draw_tarot')),
  quota_bucket text not null check (quota_bucket in ('free_week','trial_day','premium_day')),
  period_start date not null,
  used_count integer not null default 0 check (used_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, feature_key, quota_bucket, period_start)
);

create table public.billing_events (
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  event_id text not null,
  user_id uuid references auth.users(id) on delete set null,
  processing_status text not null check (processing_status in ('received','processed','failed')),
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  primary key (provider, event_id)
);
create index billing_events_by_user on public.billing_events(user_id) where user_id is not null;

-- Keep all account/billing tables private by default. Explicit owner SELECT only.
alter table public.user_access enable row level security;
alter table public.subscriptions enable row level security;
alter table public.usage_counters enable row level security;
alter table public.billing_events enable row level security;

revoke all on table public.user_access from public, anon, authenticated;
revoke all on table public.subscriptions from public, anon, authenticated;
revoke all on table public.usage_counters from public, anon, authenticated;
revoke all on table public.billing_events from public, anon, authenticated;
grant select on public.user_access, public.subscriptions, public.usage_counters to authenticated;
grant all on public.user_access, public.subscriptions, public.usage_counters, public.billing_events to service_role;

create policy user_access_owner_select on public.user_access
  for select to authenticated using (user_id = (select auth.uid()));
create policy subscriptions_owner_select on public.subscriptions
  for select to authenticated using (user_id = (select auth.uid()));
create policy usage_counters_owner_select on public.usage_counters
  for select to authenticated using (user_id = (select auth.uid()));
-- billing_events intentionally has no user-facing policy: its identifiers are back-office only.

-- Atomic quota counter. SECURITY INVOKER + execute granted only to service_role.
-- Never call this directly using a user-supplied service key or from browser code.
create function public.consume_usage(
  p_user_id uuid, p_feature_key text, p_quota_bucket text, p_period_start date, p_limit integer
) returns table (allowed boolean, used_count integer)
language plpgsql security invoker set search_path = '' as $$
declare v_used integer;
begin
  if p_user_id is null or p_period_start is null
     or p_feature_key not in ('calculate_numerology','draw_tarot')
     or p_quota_bucket not in ('free_week','trial_day','premium_day')
     or p_limit < 1 or p_limit > 10000 then
    raise exception 'Invalid quota request';
  end if;
  insert into public.usage_counters (user_id, feature_key, quota_bucket, period_start, used_count)
    values (p_user_id, p_feature_key, p_quota_bucket, p_period_start, 1)
    on conflict (user_id, feature_key, quota_bucket, period_start)
    do update set used_count = public.usage_counters.used_count + 1, updated_at = now()
      where public.usage_counters.used_count < p_limit
    returning public.usage_counters.used_count into v_used;
  if v_used is not null then
    return query select true, v_used;
  else
    select uc.used_count into v_used from public.usage_counters as uc
      where uc.user_id = p_user_id and uc.feature_key = p_feature_key
      and uc.quota_bucket = p_quota_bucket and uc.period_start = p_period_start;
    return query select false, coalesce(v_used, 0);
  end if;
end;
$$;
revoke all on function public.consume_usage(uuid,text,text,date,integer) from public, anon, authenticated;
grant execute on function public.consume_usage(uuid,text,text,date,integer) to service_role;

comment on table public.user_access is 'Only billing/entitlement state, no birth or journal data';
comment on table public.usage_counters is 'Aggregate tool counts, no fortune contents or questions';
comment on table public.billing_events is 'Provider event identity only, no card or webhook payload';
