# Definition of Done — v0.2.1

**状態は証拠のあるものだけPASS。テストファイルの存在はテスト合格ではない。** 証拠の正本は [verification/RESULTS.md](../verification/RESULTS.md) と同ディレクトリのログ（`results.json` に command / exit code / 時刻 / 環境）。
状態: **PASS**（実行して合格）/ **FAIL**（実行して不合格）/ **BLOCKED**（外部前提が未整備で実行不能）/ **NOT RUN**（実行可能だが未実行）。
「local」はこのWindows開発機のSupabase CLI 2.120.0ローカルstack（実Supabase Postgres 17.6.1イメージ + GoTrue OAuth 2.1 + PostgREST）、「PG」は使い捨て `postgres:17`（digest固定）。

## G0 Source delivery

| 項目 | 状態 | 証拠 |
|---|---|---|
| 旧 `20261014000100_initial_schema.sql` 非改変（sha256 `6e2155b0…`） | PASS | `migration_prepare.log`, `static.log` |
| P0/P1/P2データ境界、11表の制約/索引/RLS/GRANT | PASS | `db.log`, `supabase_local_sql.log` |
| 顧客MCPと運営APIの分離、任意同意と関心同意、export/revoke | PASS | `e2e_local*.json` |
| 出生/日誌/Google token/自由文を保存しない | PASS | static禁止列検査 + E2E（台帳・exportに出生日なし） |

## G1 Dependency / build（release blocker）

| 項目 | 状態 | 証拠 |
|---|---|---|
| 全pinが公式registryに実在、peer互換 | PASS | `npm view`（全pin実在）、`npm ls` 不整合なし（OS別optionalのみ） |
| 脆弱性 | PASS | `audit.log` 0件（next 15.5.19→15.5.27、postcss/sharp override） |
| 正規 `package-lock.json`、`npm ci` 再現 | PASS | `npm_ci_clean_clone.log`（fresh clone） |
| full TypeScript | PASS | `typecheck.log` |
| Next production build | PASS | `production_build.log`（env未設定でも成功） |
| Node runtime smoke（`next start`） | PASS | `e2e_local*.json`（local） |
| Vercel build / deploy（Git連携、Production `fortune-journal-mcp`） | PASS | `vercel_audit_2026-10-16.md`（f15bb55 → `dpl_DKrX…` READY、Next.js、Node 24.x、`iad1`） |
| Vercel runtime smoke（`/api/mcp` 無トークン401、PRM、`/login`） | BLOCKED | 同上。env全環境0件のため500（`APP_ORIGIN`/Supabase未設定、fail-closed）。`/api/health` のみ200。Supabase project作成とenv設定が前提（要承認） |
| PR CI（unit / database / build / supabase-local） | PASS | PR #1（run 38693864153）、マージ後の main f15bb55（run 38777543463 success） |
| 第三者Action pin | PASS | checkout v4.2.2 / setup-node v4.4.0 / supabase/setup-cli v3.0.1 をGitHub tag refと照合 |

## G2 Database（release blocker）

| 項目 | 状態 | 証拠 |
|---|---|---|
| 公式CLIで5テンプレートをmigration化、`db:check-prepared` | PASS | `migration_prepare.log`, `supabase/template-lock.json` |
| forward-fix 06/07 を manifest にhash登録、未登録migrationを拒否 | PASS | `migration_prepare.log` |
| fresh / v0.1データ入り で全migration、旧データ保持、課金の偽verifiedなし | PASS | `db.log`（PG） |
| 実Supabaseイメージで全migration適用 | PASS | `supabase_local_start.log`（local） |
| anon / A / B / service_role の読取・列権限・不正更新・課金/運営RPC否認 | PASS | `db.log`, `supabase_local_sql.log`, E2E「Data API」 |
| 同一request 10並列→1 quota（9 replay、同一readingId）、別request 10並列→Free上限3（7件 LIMIT） | PASS | `db.log` |
| 途中失敗時の原子性（quotaだけ消費しない） | PASS | `v02_negative_edge.sql`（注入トリガー） |
| 課金: 重複/経済キー重複/逆順/返金/チャージバック/通貨別cash・MRR/不整合リプレイ/未binding拒否 | PASS | `v02_billing.sql`, `v02_negative_edge.sql` |
| 課金: 実署名検証 | BLOCKED | 決済事業者未確定。webhookは501 fail-closed（E2E/smoke確認） |
| 90/400日purge、capture_key一意、FK削除cascade、同意撤回、本人export | PASS | SQLスイート + E2E（Export / Account deletion / Analytics mode） |
| Supabase advisors / lint | PASS（local） | `supabase_advisors_local.log`（WARN/ERROR 0）、`supabase_lint_local.log` |
| 実Staging projectのData API公開設定/権限/advisors | BLOCKED | Staging project未作成 |
| バックアップ/復元、移行停止時間、旧アプリ互換 | NOT RUN | 手順は `DEPLOYMENT_AND_TESTS.md` §3。旧v0.1アプリとは非互換（05） |

## G3 Customer / MCP（release blocker）

| 項目 | 状態 | 証拠 |
|---|---|---|
| Googleのみ（Email/Password/OTP/Anonymous拒否） | PASS（local） | E2E「Google-only」 |
| 実Googleログイン | BLOCKED | Staging Google OAuth client未作成 |
| OAuth discovery(401+RFC 9728)/DCR/PKCE/誤verifier拒否/code再利用拒否/同意/拒否/refresh/revoke/削除後401 | PASS（local GoTrue） | E2E |
| 有効期限切れトークン拒否 | PASS（unit） | `tests/oauth.test.mjs`（exp検査）。実期限切れのE2Eは NOT RUN |
| 同意画面: client名・callback host・未検証client警告・Origin/CSRF・他ユーザーのauthorization操作不可 | PASS（local） | E2E |
| ChatGPT / Claude 実ホストでの接続 | BLOCKED | Stagingの公開URLが必要 |
| MCP 2025 stateless と 2026-07-28 envelope の両方 | PASS（local） | E2E |
| Free/Trial/Premium判定はサーバーのみ。同意・ログインでTrial開始しない | PASS | E2E + SQL |
| 同一request再試行・別入力conflict・日付越えtarot・Free上限 | PASS（local） | E2E |
| 顧客本人Sheets作成/追記/読み戻し・拒否・重複・式注入・他人のsheet | BLOCKED | 顧客側Googleコネクタでの手動E2E（自社MCPはGoogleに触れない）。書込みルールは `get_journal_schema.writeRules` で提供（unit/E2E PASS） |
| MCP完了をSheets保存成功と表示しない、feedback明示選択、計測拒否でも基本機能 | PASS | E2E + tool記述 |
| 通信: draw_tarot / get_access_status は Auth 1 + DB 1、calculate_numerology は増加なし、期限切れ401はAuth 0 | PASS（local） | Kong実測 `verification/perf/`、[PERFORMANCE.md](PERFORMANCE.md) |
| 認証の失効即時性を維持（毎回 getUser、ローカル検証のみの受理なし） | PASS（local） | E2E revoke/削除後401、`perf/auth_probe.json` |
| Trial終了後の同一tarot再試行・停止ユーザー拒否・MCP経由10並列で1単位 | PASS（local） | E2E + `v02_forward_fix_08.sql` + `db.log`。Trial終了後replayの仕様はオーナー承認済み（2026-10-15） |
| ホストが事前ツール呼出しを省くか（ChatGPT/Claude/Codex） | BLOCKED | 実ホスト接続にStaging公開URLが必要 |
| Vercel/実Supabase上の往復時間・コールドスタート | BLOCKED | Staging未作成 |

## G4 Threads P0

| 項目 | 状態 | 証拠 |
|---|---|---|
| 承認hash不一致で公開拒否、同時claim一つ、unknownを再公開しない（DB層） | PASS | `v02_transactions.sql` |
| ネットワーク誤り時に公開POSTを再送しない、token をURLに載せない（client層、mock） | PASS | `tests/threads-client.test.mjs` |
| 事業者accountのtoken権限とAPI版、pagination、24/72/168h実観測、followers | BLOCKED | Meta権限・API版未確認、全フラグOFF |
| cron失敗/収集停止/unknown の通知先 | BLOCKED | 構造化ログ `FJ_MAINTENANCE_*` は実装・確認済み。通知先（log drain/alert）未接続 |
| 運営費用の外部申告/推定/観測不能の分離 | PASS（DB層） | `automation_runs` 制約 + `fj_operation_report` |

## G5 Business / payments / policies

| 項目 | 状態 |
|---|---|
| プライバシー通知・同意文・保存期間・export/delete連絡先・規約の公開 | BLOCKED（法務・連絡先未確定） |
| Threads投稿/AI表示/ホスト掲載と課金導線ポリシー | BLOCKED |
| 決済業種承認・実adapter・解約・署名検証・照合/返金/チャージバック | BLOCKED（501維持） |
| 更新率の母数・初回/継続区別 | PASS（SQL定義のみ、実データなし） |
| 費用・税・手数料なしで粗利/LTVを実測と称さない | PASS（レポートcaveat） |

## Go / no-go

| Gate | 判定 |
|---|---|
| ローカル Deploy-Ready（コード・migration・テスト・runbook） | **GO** |
| Vercel Production `fortune-journal-mcp`（mainから自動deploy済み） | **未設定・非公開化の判断待ち**（env 0件で `/api/mcp` 500。保護範囲All Deployments化・Production branch・Node版・env はいずれも要承認。08適用済みDBが前提） |
| Staging 構築・デプロイ | **承認待ち**（Supabase project・Staging用Vercel project（または既存projectのPreview環境）の作成、Google OAuth client、env、`db push`、Preview deploy） |
| P0 非公開運営テスト（Threads） | NO-GO（Meta権限・API版・通知先） |
| P1 無料公開 | NO-GO（実Google/実ホストOAuth E2E、Sheets手動E2E、法務文書、Staging advisors） |
| P2 課金公開 | NO-GO（決済事業者・署名・法務） |

課金だけ未完了なら課金を無効（501）にしたまま他gateを満たす範囲で進める。OAuth・RLS・full build の実Staging確認前に一般公開しない。
