# Definition of Done and current status — v0.3.0

**PASS は実行して合格したものだけ。** FAIL（実行して不合格）/ BLOCKED（外部前提がなく実行不能）/ NOT RUN（実行可能だが未実行）。証拠の正本は [verification/RESULTS.md](../verification/RESULTS.md)（command・exit code・時刻・対象commit）と同ディレクトリのログ。
「local」= このWindows開発機のSupabase CLI 2.120.0ローカルstack（Supabase Postgres 17 + GoTrue OAuth 2.1 + PostgREST）、「PG」= 使い捨て `postgres:17`（digest固定）。

## 現在地（2026-10-16）

- ローカルでDeploy-Ready。Staging未作成。リモートへの書込み・デプロイ・投稿・課金は行っていない。
- Vercel Production `fortune-journal-mcp` は main から自動deployされるが env 0件で未稼働、全URLがVercelログイン必須（[verification/vercel_audit_2026-10-16.md](../verification/vercel_audit_2026-10-16.md)）。
- DBは1本のbaseline（リモート未適用）。v0.2.1 からの変更点は [CHANGELOG.md](CHANGELOG.md)、リファクタの記録は [verification/refactor_2026-10-16.md](../verification/refactor_2026-10-16.md)。

## G1 Build / dependencies

| 項目 | 状態 | 証拠 |
|---|---|---|
| `npm ci`、`npm audit --audit-level=high` 0件 | PASS | `audit.log` |
| Prettier、static contracts、full TypeScript（noUnused*） | PASS | `format.log`, `static.log`, `typecheck.log` |
| 単体テスト（占術・HMAC・OAuth claim・7ツール契約・opsコマンド・export入力・Threads mock・計測） | PASS | `unit.log` |
| Next production build | PASS | `production_build.log` |
| Node 24 でのbuild/test | NOT RUN（local）→ CIのmatrixで実行 | `.github/workflows/ci.yml` |
| Vercel build/deploy（Git連携） | PASS（f15bb55, 2026-10-16 監査） | `vercel_audit_2026-10-16.md` |
| Vercel runtime smoke | BLOCKED | env 0件（Supabase project未作成、要承認） |
| GitHub Actions（このブランチ） | NOT RUN | push未承認 |

## G2 Database

| 項目 | 状態 | 証拠 |
|---|---|---|
| baselineのfresh適用（PG / local） | PASS | `db.log`, `supabase_local_reset.log` |
| 全public objectの権限契約（RLS・client権限なし・invoker・search_path） | PASS（PG / local） | `catalog.sql` in `db.log`, `supabase_local_sql.log` |
| 計算・Trial・上限・replay・conflict・停止・原子性 | PASS（PG / local） | `calculations.sql` |
| 並列: 別request 10→3+7、同一request 10→1+9、日付違いtarot 10→1 | PASS（PG） | `db.log` |
| 同意・撤回・コホート・流入元・評価・本人申告 | PASS（PG / local） | `privacy.sql` |
| 課金: 重複・経済キー・逆順・不整合・返金・CB・通貨別・不正イベント | PASS（PG / local） | `billing.sql` |
| 運営: 承認ハッシュ・二重claim・unknown・lease・KPIのNULL | PASS（PG / local） | `operations.sql` |
| 保持期限・アカウント削除CASCADE・課金台帳の匿名化 | PASS（PG / local） | `retention.sql`, `billing.sql` |
| dump/restore（権限契約と行数） | PASS（PG） | `db.log` |
| schema snapshot / catalog がmigrationと一致 | PASS | `schema_check.log` |
| `supabase db lint` / `db advisors`（WARN以上0） | PASS（local） | `supabase_lint_local.log`, `supabase_advisors_local.log` |
| 既存データ入りDBの移行互換 | N/A | 適用済みリモートDBが存在しない（read-only確認） |
| 実Staging DBでの適用・advisors・復元 | BLOCKED | Staging未作成 |
| 課金の実署名検証 | BLOCKED | 決済事業者未確定、webhook 501 |

## G3 Customer / MCP

| 項目 | 状態 | 証拠 |
|---|---|---|
| Googleのみ（Email/Password/OTP/Anonymous拒否） | PASS（local） | `e2e_local*.json` |
| OAuth discovery（401 + RFC 9728）/ DCR / PKCE / 誤verifier・code再利用拒否 / 同意・拒否 / refresh / revoke / 削除後401 | PASS（local） | E2E |
| 期限切れ・改ざん・ブラウザセッションtokenの401 | PASS（unit + local） | `tests/oauth.test.mjs`, E2E |
| tools/list 7件（OAuth meta・outputSchema）、2025 stateless と 2026-07-28 envelope | PASS（local） | E2E, `tests/mcp-tools.test.mjs` |
| Trial開始は初回計算・同一ID replay・別入力conflict・日付越えtarot・Free上限・Trial終了後replay・停止 | PASS（local） | E2E |
| Data APIからの読み書き不可（anon / 署名済みユーザー） | PASS（local） | E2E |
| 本人export（fingerprint・出生日なし）、任意計測の同意/撤回 | PASS（local） | E2E（analytics ON） |
| 往復: numerology/tarot/access = Auth 1 + DB 1、schema = Auth 1 + DB 0 | PASS（local） | `perf/after_off.json`（Kong実測） |
| **トークンaudienceのRFC 8707束縛（MCP仕様）** | **BLOCKED** | Supabaseが `aud=authenticated` 固定（`perf/resource_audience.json`）。緩和策と解消条件は [SECURITY.md](SECURITY.md) |
| 実Googleログイン、ChatGPT/Claude実ホスト接続、ホストが事前呼出しを省くか | BLOCKED | Staging公開URL・Google OAuth clientが必要 |
| 顧客Google Sheets（作成・追記・重複回避・式無害化・拒否時） | BLOCKED | 顧客側コネクタでの手動E2E |
| Vercel/実Supabase上の往復時間・コールドスタート | BLOCKED | Staging未作成 |

## G4 Threads（P0）

| 項目 | 状態 | 証拠 |
|---|---|---|
| 承認ハッシュ不一致の拒否、claim一つ、unknownを再公開しない（DB） | PASS | `operations.sql` |
| POSTを再送しない、tokenをURLに載せない（client、mock） | PASS | `tests/threads.test.mjs` |
| 実API（権限・API版・pagination・実観測） | BLOCKED | Meta権限未確認、全flag OFF |
| cron失敗・unknownの通知先 | BLOCKED | ログコードは実装済み、通知先未接続 |

## G5 Business / policy

| 項目 | 状態 |
|---|---|
| プライバシー通知・規約・連絡先の公開 | BLOCKED（法務未確定） |
| 決済（業種承認・adapter・解約・署名・照合） | BLOCKED（501維持） |
| 粗利/LTVを実測と称さない | PASS（レポートのcaveat） |

## Go / no-go

| Gate | 判定 |
|---|---|
| ローカル Deploy-Ready（コード・baseline・テスト・runbook） | **GO** |
| Staging構築（Supabase project、Vercel環境、Google OAuth client、env、`db push`） | 承認待ち（[OPERATIONS.md](OPERATIONS.md) §3） |
| P0 非公開運営（Threads） | NO-GO（Meta権限・通知先） |
| P1 無料公開 | NO-GO（実Google/実ホストE2E、Sheets手動E2E、audienceの扱いの決定、法務、Staging advisors） |
| P2 課金公開 | NO-GO（決済事業者・署名・法務） |

テストが存在する→合格、ローカルE2E合格→Staging合格、MCPが計算した→Google保存成功、snapshotがない→0、という読み替えはしない。
