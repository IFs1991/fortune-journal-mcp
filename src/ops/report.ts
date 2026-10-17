import {adminSupabase} from '@/src/lib/supabase/server';

const POST_ROW_LIMIT = 1000;

const CAVEATS = [
  '24h observations require actual ages 24–26 hours; null is not zero.',
  'Cohorts contain consenting near-signup users only, not all visitors.',
  'MCP calculation success is not Google Sheets save success.',
  'No customer-host ChatGPT/Claude token or inference cost is observable.',
  'MRR and cash collections are separate; currencies are not combined.',
];

/** Read-only weekly report. The independent queries run in parallel (one round trip of latency). */
export async function report(from: string, until: string) {
  const db = adminSupabase();
  const account = process.env.THREADS_ACCOUNT_ID;
  const [cohorts, posts, mrr, cash, operations, follower] = await Promise.all([
    db.rpc('fj_cohort_report', {p_from: from, p_until: until}),
    db
      .from('fj_post_24h')
      .select('*')
      .gte('published_at', from)
      .lt('published_at', until)
      .order('published_at')
      .limit(POST_ROW_LIMIT + 1),
    db.from('fj_current_mrr').select('*'),
    db.rpc('fj_revenue_report', {p_from: from, p_until: until}),
    db.rpc('fj_operation_report', {p_from: from, p_until: until}),
    account ? db.rpc('fj_follower_growth', {p_account: account, p_until: until}) : null,
  ]);
  if ([cohorts, posts, mrr, cash, operations, follower].some((reply) => reply?.error)) {
    throw new Error('REPORT_BACKEND_FAILURE');
  }
  const postRows = posts.data ?? [];
  return {
    cohorts: cohorts.data,
    post24h: postRows.slice(0, POST_ROW_LIMIT),
    postRowsTruncated: postRows.length > POST_ROW_LIMIT,
    mrrByCurrency: mrr.data,
    cash: cash.data,
    operations: operations.data,
    follower7d: follower?.data ?? null,
    caveats: CAVEATS,
  };
}
