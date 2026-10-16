export const POST_METRICS = ['views', 'likes', 'replies', 'reposts', 'quotes', 'shares'] as const;
export type PostMetric = (typeof POST_METRICS)[number];
export type PostMetrics = Record<PostMetric, number | null>;
export type InsightEntry = {
  name: string;
  period?: string;
  values?: {value: unknown; end_time?: string}[];
  total_value?: {value: unknown};
};
export function countOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : null;
}
export function insightEntries(payload: unknown): InsightEntry[] {
  if (typeof payload !== 'object' || payload === null || !('data' in payload) || !Array.isArray(payload.data))
    throw new Error('THREADS_RESPONSE_SHAPE');
  return payload.data.filter(
    (x): x is InsightEntry => !!x && typeof x === 'object' && typeof x.name === 'string',
  );
}
export function normalizePostMetrics(payload: unknown): PostMetrics {
  const result = Object.fromEntries(POST_METRICS.map((x) => [x, null])) as PostMetrics;
  for (const entry of insightEntries(payload)) {
    if (!POST_METRICS.includes(entry.name as PostMetric)) continue;
    // Refuse an incompatible aggregation period instead of silently summing it.
    if (entry.period && entry.period !== 'lifetime') continue;
    result[entry.name as PostMetric] = countOrNull(entry.total_value?.value ?? entry.values?.[0]?.value);
  }
  return result;
}
export type AccountMetric = {
  metric_name: string;
  metric_value: number | null;
  period_kind: 'point_in_time' | 'day' | 'range';
  period_start: string | null;
  period_end: string | null;
};
export function normalizeAccountMetrics(payload: unknown, since: Date, until: Date): AccountMetric[] {
  if (!Number.isFinite(+since) || !Number.isFinite(+until) || +until <= +since)
    throw new Error('INVALID_PERIOD');
  const rows: AccountMetric[] = [];
  for (const entry of insightEntries(payload)) {
    if (!['views', 'likes', 'replies', 'reposts', 'quotes', 'followers_count'].includes(entry.name)) continue;
    if (entry.name === 'followers_count') {
      rows.push({
        metric_name: entry.name,
        metric_value: countOrNull(entry.total_value?.value ?? entry.values?.[0]?.value),
        period_kind: 'point_in_time',
        period_start: null,
        period_end: null,
      });
      continue;
    }
    if (entry.total_value) {
      rows.push({
        metric_name: entry.name,
        metric_value: countOrNull(entry.total_value.value),
        period_kind: 'range',
        period_start: since.toISOString(),
        period_end: until.toISOString(),
      });
      continue;
    }
    // Only documented daily series with explicit boundaries can be normalized.
    if (entry.period === 'day' && Array.isArray(entry.values))
      for (const value of entry.values) {
        const end = value.end_time ? new Date(value.end_time) : null;
        if (!end || !Number.isFinite(+end)) continue;
        rows.push({
          metric_name: entry.name,
          metric_value: countOrNull(value.value),
          period_kind: 'day',
          period_start: new Date(+end - 86400000).toISOString(),
          period_end: end.toISOString(),
        });
      }
  }
  return rows;
}
export function dueAges(publishedAt: string, now: Date, existing: number[]): number[] {
  const age = (+now - Date.parse(publishedAt)) / 3600000;
  if (!Number.isFinite(age)) throw new Error('INVALID_PUBLISHED_AT');
  return [24, 72, 168].filter((h) => age >= h && age <= h + 2 && !existing.includes(h));
}
export function importedPost(
  value: unknown,
): {external_post_id: string; body: string; published_at: string} | null {
  if (!value || typeof value !== 'object') return null;
  const v = value as Record<string, unknown>;
  if (
    typeof v.id !== 'string' ||
    !/^\d{1,80}$/.test(v.id) ||
    typeof v.text !== 'string' ||
    !v.text.trim() ||
    [...v.text].length > 10000 ||
    typeof v.timestamp !== 'string' ||
    !Number.isFinite(Date.parse(v.timestamp)) ||
    v.is_reply === true
  )
    return null;
  return {external_post_id: v.id, body: v.text, published_at: new Date(v.timestamp).toISOString()};
}
