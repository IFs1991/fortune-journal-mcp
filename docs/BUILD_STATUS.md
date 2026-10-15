# Build status — v0.2.1 (Deploy-Ready locally; Vercel Production auto-deployed but unconfigured; Staging not created)

本番公開済み製品ではない。実行した検証は [../verification/RESULTS.md](../verification/RESULTS.md)、判定は [DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md)。

## 完了（実行証拠あり）

- 依存: 全pin実在を確認、Next 15.5.19→15.5.27（critical advisory）、postcss/sharp override、正規lockfile、fresh cloneで `npm ci` 再現、`npm audit` 0件。
- full TypeScript、Next production build、`next start` runtime smoke。
- 公式Supabase CLI 2.120.0で5テンプレートをmigration化。forward-fix 06（実Supabaseでのみ発覚した `fj_set_privacy` の `auth.users` 参照）と07（FK被覆index）。
- 使い捨てPostgres 17（fresh / v0.1 upgrade）と実Supabaseイメージの両方で全SQLスイート、10並列quota/冪等性、注入失敗の原子性、課金正規化、保持期限。
- ローカルSupabase stack（GoTrue OAuth 2.1 + PostgREST）とこのappでのE2E: Google以外のログイン拒否、Data API RLS（anon/A/B）、DCR+PKCE+同意/拒否、MCP（7ツール、2025/2026両プロトコル）、Trial/Free/quota/冪等性/日付越えtarot、refresh、revoke、アカウント削除、export、任意計測の同意/撤回、cron、署名付きops。
- `supabase db advisors`（local）WARN/ERROR 0。

## MCP通信最適化（PR #1、main f15bb55 にマージ済み）

draw_tarot / get_access_status は Auth 1 + DB 1、期限切れトークンはAuth呼出しなしで401、計測イベントは応答後。Authは毎回 `getUser()` を維持。ローカル実測と判断は [PERFORMANCE.md](PERFORMANCE.md)。**migration 08 はアプリより先に対象DBへ適用する**（現時点でFortune Journal用のリモートDBは存在しない）。

## Vercel Production（2026-10-16 監査、[verification/vercel_audit_2026-10-16.md](../verification/vercel_audit_2026-10-16.md)）

- Vercel project `fortune-journal-mcp`（team「Toshu's projects」、Pro）が GitHub に連携済みで、Production branch = `main`。**mainへのマージはそのままProduction deployになる**。f15bb55 は Production に READY（オーナー承認のうえで受け入れ）。
- 環境変数は**全環境0件**。どのSupabase projectにも接続していない。`/api/health` 200 だが、`/api/mcp`・PRM・`/login` は **500**（`APP_ORIGIN` / Supabase public env 未設定、fail-closed でデータ露出なし）。cron は毎時503（`FJ_CRON_NOT_CONFIGURED`）。
- Deployment Protection は Standard（本番ドメイン `fortune-journal-mcp.vercel.app` は公開）。Node.js 24.x（runbook/CIは22.x）、region `iad1`。
- 保護強化・Production branch・Node・env・Supabase作成の修正計画は監査ファイル末尾。いずれも未実施・要承認。

## ブロックしているもの

- Staging用Supabase project / Staging用Vercel project / Google OAuth clientが**存在しない**（read-only確認済み、2026-10-16）。作成・`db push`・env設定・deployは承認待ち。Production用Vercel project `fortune-journal-mcp` は存在するが未設定（上記）。
- 実Googleログイン、ChatGPT/Claude実ホスト接続、顧客Google Sheets手動E2E、Staging advisors。
- Meta Threads実API（権限・API版未確認）、通知先（log drain/alert）。
- 決済事業者・署名検証・法務文書（webhookは501のまま）。
- Vercel `fortune-journal-mcp` の env・保護範囲・Production branch・Node版の決定（オーナー承認待ち）。

## 暗黙の完了扱いを禁止

テストが存在する→合格、ローカルE2E合格→Staging合格、MCPが計算した→Google保存成功、顧客LLM費が見えない→無料、snapshotがない→0、という読み替えはしない。
