export const JOURNAL_SCHEMA_VERSION = '1.1';
export const JOURNAL_SHEETS = [
  { name: 'Fortune Log', headers: [
    'record_id','created_at_utc','target_date','method','algorithm_version',
    'reading_original','reading_interpretation','notes','request_id','service_reading_id','topic_optional',
  ] },
  { name: 'Life Log', headers: [
    'record_id','event_date','category','what_happened','my_actions','mood_1_to_5','notes',
  ] },
  { name: 'Review', headers: [
    'review_id','review_date','fortune_record_ids','life_record_ids','matches',
    'mismatches','unclear','what_i_learned',
  ] },
  { name: 'Profile', headers: [
    'schema_version','locale','timezone','birth_date_optional','my_preferences_optional',
  ] },
] as const;

/** Escape formula-like text if the Google Sheets integration uses USER_ENTERED input. */
export function escapeSheetText(value: string): string {
  return /^[\s]*[=+\-@]/u.test(value) ? `'${value}` : value;
}
