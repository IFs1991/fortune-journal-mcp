# Definition of Done and current status — v0.3.1

**PASS は実行して合格したものだけ。** FAIL（実行して不合格）/ BLOCKED（外部前提がなく実行不能）/ NOT RUN（実行可能だが未実行）。証拠の正本は [verification/RESULTS.md](../verification/RESULTS.md)（command・exit code・時刻・対象commit）と `verification/local/`、修正前の再現は `verification/before_fix/`。
「local」= Supabase CLI 2.120.0 のローカルstack（Supabase Postgres 17 + GoTrue OAuth 2.1 + PostgREST）、「PG」= 使い捨て `postgres:17`（digest固定）。検証は `npm run verify:local` を Node 24 / 22 で実行（GitHub Actionsは受入れ基準にしない）。

## 現在地（2026-10-17）

- PR #3（`fd57d5e`）をベースに P0（認証境界・audience・redirect・MCP Origin）、P1（課金整合性・maintenance・Threads）を修正し、ローカルで全件PASS（Node 24・22）。
- Staging未作成。リモートへの書込み・デプロイ・投稿・課金は行っていない。Vercel Production `fortune-journal-mcp` は main から自動deployされるが env 0件・全URL保護（2026-10-16 監査）。
- DBは1本のbaseline（リモート未適用なので編集可）。

## G1 Build / dependencies

| 項目 | 状態 | 証拠 |
|---|---|---|
| `npm ci`、`npm audit --audit-level=high` 0件 | PASS（Node 24・22） | `local/node*/npm_ci.log`, `audit.log` |
| Prettier、static contracts、full TypeScript | PASS（Node 24・22） | `format.log`, `static.log`, `typecheck.log` |
| 単体テスト 68件 | PASS（Node 24・22） | `unit.log` |
| Next production build | PASS（Node 24・22） | `build.log` |
| Vercel build/deploy（Git連携） | PASS（f15bb55、2026-10-16 監査）。このブランチは NOT RUN（push後のPreviewで確認） | `vercel_audit_2026-10-16.md` |
| Vercel runtime smoke（`scripts/smoke-remote.mjs`） | BLOCKED | env 0件・Supabase project未作成。localhostでは PASS 8/8 |

## G2 Database

| 項目 | 状態 | 証拠 |
|---|---|---|
| baselineのfresh適用、全public objectの権限契約（hookは `supabase_auth_admin` のみ例外） | PASS（PG / local） | `db_pg17.log`, `supabase_sql.log` |
| 計算・Trial・上限・replay・conflict・停止・原子性・並列 | PASS（PG / local） | `calculations.sql`, `db_pg17.log` |
| 課金: 重複・経済キー（重複通知のsnapshot適用）・逆順・同時刻の全項目比較とfail closed・reconciled・支払失敗・解約予約・返金・CB・通貨別・削除後の返金記録 | PASS（PG / local） | `billing.sql` |
| 課金の並列（同一入金20並列 → cash 1件・最新snapshot） | PASS（PG） | `db_pg17.log` |
| 運営: 承認ハッシュ・二重claim・unknown・未公開確定の再claim・resolve・lease・試行切れの `exhausted`・KPIのNULL | PASS（PG / local） | `operations.sql` |
| 保持期限・アカウント削除・課金bindingの非識別化 | PASS（PG / local） | `retention.sql`, `billing.sql` |
| dump/restore、schema drift | PASS | `db_pg17.log`, `schema_drift.log` |
| `supabase db lint` / `db advisors`（WARN以上0） | PASS（local） | `supabase_lint.log`, `supabase_advisors.log` |
| 実Staging DBでの適用・advisors・復元 | BLOCKED | Staging未作成 |
| 課金の実署名検証・事業者sandbox E2E | BLOCKED | 決済事業者未確定、webhook 501 |

## G3 Customer / MCP

| 項目 | 状態 | 証拠 |
|---|---|---|
| Googleのみ（Email/Password/OTP/Anonymous拒否） | PASS（local） | E2E |
| OAuth discovery（401 + RFC 9728）/ DCR / PKCE / 誤verifier・code再利用拒否 / 同意・拒否 / refresh / revoke / 削除後401 | PASS（local） | E2E |
| **MCP OAuth tokenで本人Web API（export・同意・解除・削除・ログイン画面）を操作できない**（偽造cookie・binding付き偽造・Bearerのみ・binding無し・他人のbinding） | PASS（local）。修正前はFAIL（export 200） | E2E, `before_fix/` |
| CSRF（Origin欠落・外部Origin・cross/same-site・text/plain本文） | PASS（unit + local） | `tests/url.test.mjs`, E2E |
| token audience: OAuth tokenは `aud=urn:fortune-journal:mcp` のみ、それ以外は401 | PASS（unit + local、hook実機） | E2E, `auth_hook.sql` |
| RFC 8707 の AS側resource束縛 | BLOCKED（Supabase非対応: hook入力にresourceなし。project専用化で緩和） | [SECURITY.md](SECURITY.md) |
| open redirect（30ベクタ） | PASS（unit）。修正前はFAIL | `tests/url.test.mjs`, `before_fix/` |
| MCP Origin 403 / Host 421 / body 413 / rate limit 429 | PASS（unit + local） | E2E, `tests/rate-limit.test.mjs` |
| 期限切れ・改ざん・ブラウザセッションtokenの401 | PASS（unit + local） | E2E |
| tools/list 7件（名称・入出力schema不変） | PASS（local） | E2E, `check:static` |
| Trial開始・replay・conflict・日付越えtarot・Free上限・Trial終了後・停止 | PASS（local） | E2E |
| 本人export（fingerprint・出生日なし、他人の行なし）、任意計測の同意/撤回 | PASS（local） | E2E（ON） |
| 実Googleログイン（binding cookieの実発行）、ChatGPT/Claude実ホスト接続、最初の鑑定のホスト表示 | BLOCKED | Staging公開URL・Google OAuth client |
| 顧客Google Sheets | BLOCKED | 顧客側コネクタでの手動E2E |
| Vercel/実Supabase上の往復時間 | BLOCKED | Staging未作成 |

## G4 Operations / Threads

| 項目 | 状態 | 証拠 |
|---|---|---|
| maintenance: 試行切れ・失敗を成功扱いしない、retryable/permanent、cron 500 | PASS（unit + 実DB + local E2E）。修正前はFAIL（200 OK） | `tests/maintenance.test.mjs`, `ops_state_machines.log`, E2E |
| Threads: success / failed / unknown、unknownの再投稿なし、記録失敗の通知、resolve_publish | PASS（実DB + 偽装Threads）。修正前はFAIL | `ops_state_machines.log`, `operations.sql` |
| POSTを再送しない、tokenをURLに載せない | PASS（unit） | `tests/threads.test.mjs` |
| 実API（権限・API版・実観測） | BLOCKED | Meta権限未確認、全flag OFF |
| cron失敗・unknownの通知先 | BLOCKED | ログコードは実装済み、通知先（log drain）未接続 |

## G5 Business / policy

| 項目 | 状態 |
|---|---|
| プライバシーポリシー・利用規約・問い合わせ窓口の公開 | BLOCKED（法務・連絡先未確定。必要項目は [OPERATIONS.md](OPERATIONS.md) §8） |
| 決済（業種承認・adapter・解約・署名・照合） | BLOCKED（webhook 501、checkoutなし: `check:static`） |
| 無料βと有料公開の機能分離 | PASS（文書化: [BILLING_PROVIDER.md](BILLING_PROVIDER.md)、Premiumは検証済みsubscriptionなしに付与されない: `billing.sql`） |
| 粗利/LTVを実測と称さない | PASS（レポートのcaveat） |

## リリース判定

| 段階 | 判定 | 根拠 / 残条件 |
|---|---|---|
| **A. ローカルMVP完成**（既存機能・P0修正・全回帰テスト・ビルド） | **GO** | Node 24・22で `verify:local` 16ステップ全PASS（unit 68、PG/local SQL全スイート、ops 6、E2E 21+22）。P0 4件とP1 5件は修正前の失敗を再現済み |
| **B. 無料限定β公開** | **BLOCKED** | 外部前提が未充足: Staging Supabase project作成・baseline適用・**Auth Hook有効化**・Google OAuth client・Vercel env（`check-env` PASS）・Firewall rate limit・Deployment Protection解除の判断（いずれも★承認）→ Stagingで実OAuth・ChatGPT/Claude接続・smoke・§3.5のE2E。法務3点と通知先も未整備。コード上の阻害要因は見つかっていない |
| **C. 一般向け有料公開** | **NO-GO** | Bの全条件に加え、決済事業者・署名付きwebhook adapter・支払/権限反映/解約/返金のsandbox E2E・定期照合・障害時の課金照合手順が未実装（webhookは意図的に501） |

テストが存在する→合格、ローカルE2E合格→Staging合格、MCPが計算した→Google保存成功、snapshotがない→0、という読み替えはしない。
