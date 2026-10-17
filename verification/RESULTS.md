# Verification results — 2026-10-17, branch `fix/release-hardening` (base PR #3 `fd57d5e`), code commit `f6897dc`

このファイルは**実行したものだけ**をPASSとする。各ステップの command・exit code・開始/終了時刻は `local/node24/summary.json` と `local/node22/summary.json`、出力は同ディレクトリの同名ログ（各ログ先頭に command・commit・node）。
実行: `npm run verify:local -- --npm-ci`（[scripts/verify-local.sh](../scripts/verify-local.sh)）を Node **24.22.0** と **22.22.0** で各1回。どちらも作業ツリーはclean（`workingTreeClean: true`）。
環境: Linux コンテナ（Claude Code クラウドセッション）、npm 10.9、Docker 29.8.2、Supabase CLI 2.120.0（`supabase/postgres:17.11.0.004`、GoTrue OAuth 2.1、PostgREST）、psql 16 client、使い捨て `postgres:17`（digest固定）。**GitHub Actionsは使っていない。リモートのSupabase/Vercelには読取りも書込みもしていない。**

## ローカル検証（A: ローカルMVP の根拠）

| 検証 | Node 24 | Node 22 | 範囲 |
|---|---|---|---|
| `npm ci` | PASS | PASS | lockfileから再インストール |
| Prettier / 静的契約 / TypeScript（noUnused*） | PASS | PASS | 7ツール固定、MCP↔ops境界、webhook 501、billing routeはwebhookのみ、`.mcp.json` type http、env例 |
| 単体テスト | PASS 68/68 | PASS 68/68 | audience・Webセッションclaim・binding・redirect 30ベクタ・CSRF・MCP Origin/Host・rate limit・maintenance分類・resolve_publish・既存全件 |
| `npm audit --audit-level=high` | PASS（0件） | PASS（0件） | |
| 使い捨てPG17: 全SQLスイート（auth_hook・billing・calculations・catalog・operations・privacy・retention）、並列（計算10並列・**課金20並列**）、dump/restore | PASS | PASS | `db_pg17.log` |
| schema snapshot / catalog drift | PASS | PASS | `schema_drift.log` |
| local Supabase: `db reset`・全SQLスイート（実イメージ）・`db lint`（warning以上で失敗）・`db advisors`（WARN以上で失敗） | PASS | PASS | lintは初回に `fj_access_token_hook` のvolatilityを検出 → 修正（commit `3a44f60`） |
| 運営状態機械（実DB + Threads偽装）6件 | PASS 6/6 | PASS 6/6 | success / failed→再試行 / unknown→再投稿なし→resolve / 不正応答→resolve published / 成功記録失敗→unknownにID / purge試行切れ→失敗 |
| Next production build（ローカルstackのenv） | PASS | PASS | |
| E2E analytics/ops OFF | PASS 21/21 | PASS 21/21 | `e2e_analytics_off.json` |
| E2E analytics/ops ON | PASS 22/22 | PASS 22/22 | `e2e_analytics_on.json` |
| read-only smoke（`scripts/smoke-remote.mjs`）をlocalhostに | PASS 8/8 | — | `local/smoke_remote_localhost.txt`（AS metadataはローカルCLIでは path-appended 形式のみ） |

E2Eの追加範囲（v0.3.1）: OAuth tokenの `aud = urn:fortune-journal:mcp`（初回・refresh後）、ブラウザtokenはaud不変 / 有効bearerでも外部Origin 403・`null` Origin 403・外部Host 421・64KiB超 413 / **MCP OAuth tokenを詰めた偽造cookie・偽造cookie+binding・Bearerのみ・binding無しの本物cookie・他人のbindingで export/preferences/revoke/delete/ログイン画面がすべて拒否**、ユーザーが削除されないこと / 本物のbound sessionでもcross-site export 403・text/plain削除403・same-site削除403 / `user_id` クエリで他人の行が出ない / exhausted purgeでcron 500。既存範囲（Google以外のログイン拒否、Data API拒否、DCR+PKCE、同意・拒否・他人による承認不可、Trial開始・replay・conflict・Free上限・Trial後、refresh、revoke、削除後401、ops HMAC、並列draw、停止）は継続。

## 修正前の再現（`before_fix/`、PR #3 `fd57d5e` のコード）

| 不具合 | 修正前の観測 | 証拠 | 修正後 |
|---|---|---|---|
| P0 MCP OAuth tokenで本人Web APIを操作 | `export with forged cookie: 200` | `before_fix/e2e_local_on_fd57d5e.log` | 401（同じE2E step PASS） |
| P0 audience | OAuth tokenの `aud="authenticated"`、事前検査がそれを受理（`true`） | 同上、`redirect_and_audience_fd57d5e.txt` | `aud=urn:fortune-journal:mcp` のみ受理 |
| P0 open redirect | `"/\t/evil.example"` → `https://evil.example` | `redirect_and_audience_fd57d5e.txt` | `/login` |
| P0 MCP Origin | 有効bearer + `Origin: https://evil.example` → 200 | `e2e_local_on_fd57d5e.log` | 403 |
| P1 重複入金通知で新しい契約状態を無視 | `{"duplicate": true, "stateApplied": false}`、Premium付与されず | `billing_fd57d5e.txt`（新しいbilling.sqlをbilling修正前のSQLのlocal stackで実行） | 適用、cashは1件 |
| P1 削除後の返金が記録されない | `BILLING_BINDING_REQUIRED`、net cash 499 のまま | `billing_fd57d5e.txt` | 記録（user_id NULL）、net 0 |
| P1 同時刻のplan/価格/解約予約変更を見落とす | `older_or_identical` | `billing_fd57d5e.txt` | `needs_reconciliation`（権限が食い違えばPremium停止） |
| P1 maintenanceの試行切れが成功 | HTTP 200 `{"results":[]}`、`FJ_MAINTENANCE_OK failures=0` | `maintenance_cron_fd57d5e.txt` | 500、`PURGE_RETRIES_EXHAUSTED retryable:false` |
| P1 Threadsの曖昧な結果 | container作成失敗（未公開確定）も `publish_unknown` で再試行不能、記録失敗を無視、人の確定手段なし | `ops_state_machines_fd57d5e.txt`（同じ統合テストを旧コードで実行: 0/6） | success / failed / unknown、`recorded`、`resolve_publish` |

`ops_state_machines_fd57d5e.txt` の6件の失敗のうち1件目（成功時）は応答形の変更（`outcome` 追加）だけが理由で、旧コードも公開自体は記録していた。

## 実行していない / できないもの

| 項目 | 状態 | 理由 |
|---|---|---|
| Staging（Supabase project・Vercel Preview env・Auth Hook有効化・db push） | BLOCKED | Fortune Journal用のSupabase projectが存在しない。作成・設定はオーナー承認が必要（AGENTS.md §2） |
| 実Googleログイン（binding cookieの実発行）、ChatGPT/Claude実ホスト接続、hosted Supabaseでのhook挙動 | BLOCKED | Staging公開URLとGoogle OAuth clientが必要。ローカルではmagic linkセッション + 同じ鍵で計算したbinding cookieで代替した（callbackでの発行処理自体は単体レベル） |
| Vercel Firewall rate limit、Deployment Protection解除、通知先（log drain） | BLOCKED | 本番/Preview設定変更は承認が必要 |
| 顧客Google Sheets、Meta Threads実API、決済 | BLOCKED | 顧客側コネクタの手動E2E、Meta権限、決済事業者が未確定（webhook 501） |
| プライバシーポリシー・利用規約・問い合わせ窓口 | BLOCKED | 法務文面と実在の連絡先が未確定（仮の文面は作らない） |
| GitHub Actions | 不使用 | 指示により受入れ基準にしない |

過去の記録（v0.3.0 `fd0d36f` の `results.json`・各ログ・`perf/`）は同ディレクトリに残している（このファイルが現在の正本）。
