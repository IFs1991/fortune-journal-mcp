# Build status — v0.2.1 (Deploy-Ready locally, Staging not created)

本番公開済み製品ではない。実行した検証は [../verification/RESULTS.md](../verification/RESULTS.md)、判定は [DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md)。

## 完了（実行証拠あり）

- 依存: 全pin実在を確認、Next 15.5.19→15.5.27（critical advisory）、postcss/sharp override、正規lockfile、fresh cloneで `npm ci` 再現、`npm audit` 0件。
- full TypeScript、Next production build、`next start` runtime smoke。
- 公式Supabase CLI 2.120.0で5テンプレートをmigration化。forward-fix 06（実Supabaseでのみ発覚した `fj_set_privacy` の `auth.users` 参照）と07（FK被覆index）。
- 使い捨てPostgres 17（fresh / v0.1 upgrade）と実Supabaseイメージの両方で全SQLスイート、10並列quota/冪等性、注入失敗の原子性、課金正規化、保持期限。
- ローカルSupabase stack（GoTrue OAuth 2.1 + PostgREST）とこのappでのE2E: Google以外のログイン拒否、Data API RLS（anon/A/B）、DCR+PKCE+同意/拒否、MCP（7ツール、2025/2026両プロトコル）、Trial/Free/quota/冪等性/日付越えtarot、refresh、revoke、アカウント削除、export、任意計測の同意/撤回、cron、署名付きops。
- `supabase db advisors`（local）WARN/ERROR 0。

## 未リリース変更（MCP通信最適化）

draw_tarot / get_access_status は Auth 1 + DB 1、期限切れトークンはAuth呼出しなしで401、計測イベントは応答後。Authは毎回 `getUser()` を維持。ローカル実測と判断は [PERFORMANCE.md](PERFORMANCE.md)。migration 08 はアプリより先に適用する。

## ブロックしているもの

- Staging用Supabase project / Vercel project / Google OAuth clientが**存在しない**（read-only確認済み）。作成・`db push`・deployは承認待ち。
- 実Googleログイン、ChatGPT/Claude実ホスト接続、顧客Google Sheets手動E2E、Staging advisors。
- Meta Threads実API（権限・API版未確認）、通知先（log drain/alert）。
- 決済事業者・署名検証・法務文書（webhookは501のまま）。
- CI: mainの直近runは e2e の `.ts` import（Node 22.16）でFAIL。修正はPR #1で全job PASS（未マージ）。

## 暗黙の完了扱いを禁止

テストが存在する→合格、ローカルE2E合格→Staging合格、MCPが計算した→Google保存成功、顧客LLM費が見えない→無料、snapshotがない→0、という読み替えはしない。
