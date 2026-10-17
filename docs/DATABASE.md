# Database design

- **適用元の正本**: `supabase/migrations/`（現在は `20261016022037_baseline.sql` 1本）。
- **現在の完成形（生成物、手で直さない）**: [supabase/schema.sql](../supabase/schema.sql)（`pg_dump --schema-only`）と [generated/DB_CATALOG.md](generated/DB_CATALOG.md)（表・view・RPC・index・FK・権限の一覧）。`npm run db:schema` で再生成し、CIが差分を拒否する。
- このファイルは**設計理由**だけを書く。列の一覧は生成物を見る。

## 前提と方針

- Supabase Postgres 17。Supabase Auth の `auth.users` を所有者として参照し、独自のユーザー表は作らない。
- **Data APIは製品の経路ではない。** 全表RLS有効・ポリシーなし・anon/authenticatedの権限なし。アプリは検証済みAuthユーザーのIDだけを使い service_role で呼ぶ。RLSは誤ってGRANTを足した場合の二重防御。
- 全関数 `SECURITY INVOKER`、`search_path = ''`、EXECUTEはservice_roleのみ。原子性が必要な判定（料金・上限・冪等性・課金順序・公開状態機械）はDB関数の1トランザクションで行い、TypeScriptに同じ規則を書かない。
- 保存しないもの: 出生情報、相談・鑑定本文、日誌、自由記述、SheetsのID/内容/トークン、生Webhook、カード情報。

## Baseline化（2026-10-16）

v0.1初期 + v0.2追加5本 + forward-fix 3本 + テンプレート + manifestの履歴を、完成形を直接作る1本に置き換えた。条件（read-onlyで確認）: Fortune Journal用のSupabase projectが存在しない（`supabase projects list`）、リンクなし、Vercel envは0件 = 適用済みのリモートDBも顧客データもない。旧履歴はGit（コミット `9b952ee` の親まで）に残る。
`supabase/applied-migrations.json` が空の間はbaselineを作り直してよい。最初の承認済み `db push` 以降は、登録したファイルを変更せず新しいmigrationで直す（`check:static` が検査）。

## 表（10）

| 表 | 粒度 / キー | 用途と読み書き | 保持 | 判断 |
|---|---|---|---|---|
| `user_access` | 1ユーザー / `user_id`（auth.users CASCADE） | Trial期間、停止、任意同意、初回計算時刻。計算ごとに行ロック（読み+まれに更新） | アカウント期間中 | 維持 |
| `subscriptions` | 事業者契約 / `id`、`(provider, provider_subscription_id)` 一意 | サーバーが作る課金binding + 検証済み最新状態。tier判定で読む | アカウント削除で `user_id`・`provider_customer_id` をNULL（bindingは残す: 削除後の返金・CBを台帳に載せるため。NULLユーザーは何も付与しない） | 変更（2026-10-17: CASCADE→de-identify） |
| `user_readings` | 1リクエスト / `(user_id, request_id)` 一意 | **利用1回 = 1行**。冪等性と利用上限の正本。計算ごとにINSERT（replay/拒否は書かない） | 90日 | 維持（`usage_counters` を吸収、`quota_bucket` と `quota_period_start` を削除） |
| `funnel_events` | ユーザー × dedupe key | 同意済みの任意イベント（登録・接続・計算・本人申告）。KPI用 | 90日、撤回で削除 | 維持（投稿からの `experiment_id` コピー列を削除。`post_id` から辿る） |
| `reading_feedback` | ユーザー × reading | 固定ラベルの任意評価。複合FKで他人のreadingに付けられない | readingと連動、撤回で削除 | 維持 |
| `billing_events` | `(provider, event_id)`、`(provider, economic_key)` 一意 | 検証済み課金イベントの台帳。`fj_apply_billing` だけが書く | 自動削除しない（法定保持未確定）。削除時 `user_id` をNULL | 維持（`processing_status`・`processed_at`・`verified_at`・`error_code` を `state_disposition` に置換） |
| `fortune_posts` | 投稿 / `id`、`(account_key, external_post_id)` 一意 | 運営者の公開投稿、承認ハッシュ、公開状態 | 削除しない | 維持（定数列 `platform`、未使用 `body_length`、未使用状態 `failed`/`archived`、未使用index 2本を削除） |
| `automation_runs` | `(task, idempotency_key)` | 運営処理のlease・試行・費用の出所 | 成功/失敗は90日。unknownは残す | 維持（未使用 `billing_reconcile`・`operator` を削除） |
| `post_metric_snapshots` | 投稿 × run | 投稿の実観測lifetime値（24/72/168h予定 or 手動） | 400日 | 維持（定数列 `metric_period`、重複index 2本、run FKを削除） |
| `account_metric_snapshots` | run × account × metric × 期間 | フォロワー（時点値）と期間値をLONG形式で | 400日 | 維持（`capture_key` を `run_id` に統合、FK・indexを削除） |

### 削除した表: `usage_counters`

旧設計は「カウンタ + 台帳」の二重記録だった（カウンタ増加後に台帳INSERTが失敗しないよう同じトランザクションに入れる必要があり、purgeも2系統）。`user_readings` は新規消費のときだけ1行書かれるので、上限は「同じユーザー・機能・tierで期間開始以降の行数」で数えられる。数える前に `user_access` 行を `FOR UPDATE` で取っているため並列でも上限を超えない（READ COMMITTEDは文ごとに新しいsnapshot。`scripts/test-db.sh` の10並列で確認）。Premiumでも1日200行が上限なので数える量は小さい。マージで正規化は崩れない（集計値という派生データを消しただけ）。

### 統合しなかったもの

- `trial_started_at` と `first_calculated_at` は現行方針では同時に入るが、意味が違う（料金方針 vs KPIの事実）。方針が変われば分かれるので残す。
- `funnel_events` と `reading_feedback`、`billing_events` と `subscriptions` は粒度とライフサイクルが違うので統合しない。

## 関数（RPC 17 + trigger 1）

| 関数 | 呼ぶ所 | DB内に置く理由 |
|---|---|---|
| `fj_access_status` | `get_access_status`、`fj_record_calculation` 内 | tierの規則の唯一の場所。読み取り専用（STABLE） |
| `fj_record_calculation` | `calculate_numerology`, `draw_tarot` | ロック・Trial開始・replay・上限・台帳・任意イベントを1トランザクションで。上限値（Free 3/ISO週・Trial 100/日・Premium 200/日）はここだけ |
| `fj_set_privacy` | `/api/account/preferences` | 同意更新と撤回時の削除を原子的に。登録時刻は検証済みAuthユーザーから渡す（service_roleは `auth.users` を読めない） |
| `fj_set_attribution` | 同上 | 登録イベントの流入元を「unknownを埋める / 署名リンクで上書き」だけに制限 |
| `fj_record_funnel` | `get_account_profile`（応答後）, `report_journal_action` | 同意確認とdedupeを撤回と同じロック順で |
| `fj_submit_feedback` | `submit_reading_feedback` | 同意確認と本人readingの確認 |
| `fj_apply_billing` | 将来の決済adapter（未接続） | 重複・経済事象・順序・不整合の判定とsnapshot適用を1トランザクションで |
| `fj_begin_run` / `fj_finish_run` | `src/ops/runs.ts` | lease取得と試行回数（最大3、公開は再試行しない） |
| `fj_approve_post` / `fj_claim_publish` / `fj_finish_publish` | `src/ops/posts.ts` | 本文ハッシュ拘束の承認と、二重公開しない状態機械。ロック順は常に post → run |
| `fj_cohort_report` / `fj_revenue_report` / `fj_follower_growth` / `fj_operation_report` | `src/ops/report.ts` | 成熟していない母数・欠測をNULLで返す集計定義の正本（[KPI_DICTIONARY.md](KPI_DICTIONARY.md)） |
| `fj_purge_expired` | cron | 保持期限と期限切れpublish leaseの `unknown` 化 |
| `fj_guard_post_edit`（trigger） | `fortune_posts` 更新時 | 公開中/済みの本文は不変、下書きの編集は承認取消し |

削除: `consume_usage`（v0.1、v0.2で無効化済み）、`fj_access_snapshot`（`fj_access_status` に置換し、TypeScript側のtier判定 `resolveEntitlement` を削除）。`fj_record_funnel` の未使用引数 `p_post_id` を削除。

views（`fj_post_24h`, `fj_cash_events`, `fj_current_mrr`）は `security_invoker` で service_role だけが読む。

## Index

FKはすべて先頭列が一致するindexでカバー（purgeのCASCADEで子表を全走査しない）。削除したindexは「どのクエリの述語にもならない」「先頭列が別indexで覆われる」ものだけで、統計に基づく判断ではない:
`fortune_posts_due`（予約公開ループは存在しない）、`fortune_posts_experiment`（実験列で検索するクエリがない）、`post_snapshots_observation` / `post_snapshots_target`（全クエリが `post_id` で絞り、`(post_id, run_id)` 一意indexで足りる。1投稿あたり数行）、`account_snapshots_run`（FK削除）。
`user_readings(user_id, calculated_at)` は上限カウントとD7コホートの両方に使う。purgeの `calculated_at < now()-90日` は日次の全表走査になるが、毎回のINSERTに書込み増幅を足すより安い規模と判断（数百万行を超えたら `(calculated_at)` を追加）。

## 保持期限（運用上の提案値。法定期間ではない）

台帳・任意イベント 90日、run（成功/失敗）90日、snapshot 400日、公開unknownと課金は自動削除しない。同意設定・初回利用日時はアカウント期間中。アカウント削除は `auth.users` からCASCADE（課金台帳と `subscriptions` のbindingは `user_id` をNULLにした行が残る。`provider_subscription_id` で事業者側と結合可能なので匿名化ではない）。

## テスト（`supabase/tests/`）

| スイート | 内容 |
|---|---|
| `catalog.sql` | public schemaの**全**表・view・関数の権限契約（RLS、client権限なし、invoker、search_path、service_roleのみ）。read-onlyでStagingにも流せる |
| `calculations.sql` | Trial開始、tier、上限、replay/conflict、日付越えtarot、Trial終了後replay、停止、topic同意、途中失敗の原子性 |
| `privacy.sql` | 同意・撤回、登録コホート（捏造しない）、流入元、評価・本人申告、他人のreading拒否 |
| `billing.sql` | 重複、経済キー（重複通知の新しいsnapshotは適用）、逆順、同時刻不整合（plan・価格・解約予約・間隔・通貨も比較、権限が食い違えばfail closed、`reconciled` で解消）、支払失敗、解約予約、返金・チャージバック、通貨別、不正イベント、削除後の返金記録と匿名化 |
| `operations.sql` | 承認ハッシュ、二重claim、unknown再公開禁止、lease、試行上限、snapshot定義、KPIのNULL |
| `retention.sql` | purgeの対象と残すもの、アカウント削除のCASCADE |

`scripts/test-db.sh` は加えて10並列（別request→3+7、同一request→1+9、日付違いtarot→1）と `pg_dump`/`pg_restore` 往復を確認する。`scripts/test-supabase-local.sh` は同じスイートを実Supabaseイメージで流す。
