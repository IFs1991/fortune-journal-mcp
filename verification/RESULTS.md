# Verification results — 2026-10-16, branch `refactor/pre-release-baseline`, code commit `fd0d36f`

このファイルは**実行したものだけ**をPASSとする。command・exit code・開始時刻・所要時間は [results.json](results.json)、出力は同名ログ（各ログ先頭に command と commit）。
環境: Windows 11 + Git Bash、Node 22.22.2、npm 10.9.7、Docker 29.8.2、Supabase CLI 2.120.0、psql 17.11。
「local stack」= Supabase CLIのローカルstack（Supabase Postgres 17 + GoTrue OAuth 2.1 + PostgREST、project_id `fortune-journal-local`、network `fj_local_net`）。**リモートのSupabase/Vercelには一切書き込んでいない**（read-onlyの `supabase projects list` と `vercel env ls` のみ）。

| 検証 | 結果 | 範囲 / 証拠 |
|---|---|---|
| fresh clone で `npm ci` + format + static + unit + typecheck | **PASS** | `npm_ci_clean_clone.log` |
| Prettier check | **PASS** | `format.log` |
| 静的契約 | **PASS** | migration形式・1トランザクション・DEFINER禁止・禁止列、applied-migrations、MCP↔ops境界、7ツール、ops strict、webhook 501、flags既定OFF — `static.log` |
| 単体テスト | **PASS 53/0** | 占術（タロット固定値）、日付、URL/Origin、HMAC/参照リンク、OAuth claim、7ツールの登録契約・認証ゲート・失敗コード、opsコマンド、export入力、Threads正規化とmock client、計測 — `unit.log` |
| full TypeScript（noUnusedLocals/Parameters） | **PASS** | `typecheck.log` |
| Next production build（CIと同じplaceholder env） | **PASS** | `production_build.log` |
| `npm audit --audit-level=high` | **PASS 0件** | `audit.log` |
| 使い捨てPostgres 17 | **PASS** | baseline適用、6スイート、10並列（別request→3+7、同一request→1+9、日付違いtarot→1）、dump/restore後の権限契約と行数 — `db.log` |
| schema snapshot / catalog の一致 | **PASS** | `schema_check.log` |
| local stack: `db reset`（baseline適用） | **PASS** | `supabase_local_reset.log` |
| local stack: 全SQLスイート（実Supabaseイメージ） | **PASS 6/6** | `supabase_local_sql.log` |
| `supabase db lint`（local） | **PASS** | `supabase_lint_local.log` |
| `supabase db advisors`（local、WARN以上で失敗） | **PASS（0件）** | `supabase_advisors_local.log`。INFOは未使用index 2（新規DB）とRLS no-policy 10（意図的なdeny-all） — `supabase_advisors_local_info.log` |
| E2E local（analytics/ops OFF） | **PASS 19/19** | `e2e_local.json`, `e2e_local.log`（app buildは `e2e_build.log`） |
| E2E local（analytics/ops ON） | **PASS 20/20** | `e2e_local_analytics_ops.json`, `e2e_local_analytics_ops.log` |
| 性能（Before 3de9f3c / After、HTTP n=100、pgbench） | **実測済み** | `perf/v030_*`、要約は [docs/PERFORMANCE.md](../docs/PERFORMANCE.md) §4 |
| token audienceのresource束縛（ローカル実測） | **束縛されない** → DoDでBLOCKED | `perf/resource_audience.json` |
| Node 24 でのbuild/test | **NOT RUN（local）** | CIのmatrixに追加済み、push未承認 |
| GitHub Actions（このブランチ） | **NOT RUN** | push未承認 |
| Vercel runtime smoke / Staging Supabase | **BLOCKED** | env 0件、Fortune Journal用Supabase projectなし（`vercel_audit_2026-10-16.md`） |
| 実Googleログイン / ChatGPT・Claude実ホスト / 顧客Sheets / Meta Threads / 決済 | **BLOCKED** | Staging公開URL・Google OAuth client・Meta権限・決済事業者が必要 |

E2Eの範囲（両モード）: Google以外のログイン拒否、anonと署名済みユーザーのData API全拒否（表・RPC・他人のaccess status）、DCR+PKCE（誤verifier・code再利用拒否）、同意画面（client名・callback host・unverified・Origin/セッション必須）、ブラウザセッションJWT・ゴミ・改ざんtokenは401+RFC 9728、tools/list 7件（`_meta.securitySchemes`・outputSchema）、`initialize` と 2026-07-28 envelope、初回計算でTrial開始、同一requestId replay・別入力conflict、日付越えtarot replay、Free 3回/ISO週・Free tarot拒否・Trial終了後の同一tarot replay（消費なし）、本人export（fingerprint・出生日なし）、refresh、revoke後のaccess/refresh失効、deny→`access_denied`、他ユーザーによる承認不可、cron認証とpurge、署名付きops（無署名・改ざん・期限切れ拒否）、同一drawId 10並列→1単位、停止アカウントの拒否、アカウント削除後のtoken失効。ONモードは加えて同意前の接続イベントなし・同意後に応答後1件、analytics/interestの別同意、topic gating、feedback/report（他人のreading拒否）、撤回による任意データ削除。

## このブランチで実行中に見つけて直した不具合

1. export が `resource=__proto__` 等のprototypeキーを受理し503になっていた（`in` 演算子）→ `Object.hasOwn`、unitテスト追加。
2. `fj_record_calculation` が毎回 `user_access` 行を書き換えていた（`first_calculated_at = coalesce(...)`）→ 未設定時だけ更新。
3. `src/lib/env.ts` から `node:crypto` を含む秘密読取りがブラウザbundleに入りbuildが失敗した（リファクタ中に発生）→ `src/lib/secrets.ts` に分離。

過去の検証記録（v0.2.1 / PR #1）はGit履歴の `verification/` にある。PR #1 の性能生データ `perf/before_*.json`・`after_*.json`・`auth_probe.json`・`expired_token_after.json` は残している。
