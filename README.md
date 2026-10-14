# Fortune Journal MCP — v0.2.1 Growth & Privacy

**TypeScript / Vercel / Supabase。顧客の占い手帳は顧客自身のGoogle Sheetsへ。**

追加提案を、投稿運用・集客計測・任意フィードバック・課金台帳・保守に統合したソース一式です。管理ダッシュボード、Railway、独自LLM推論基盤は追加しません。

> **リリース状態：ローカルDeploy-Ready／Staging未作成。** lockfile・full型検査・Nextビルド・公式CLIでのmigration化・使い捨てPostgresと実SupabaseイメージでのRLS/同時実行テスト・ローカルSupabase stackでのOAuth 2.1+MCP E2Eは実行済み（[検証記録](verification/RESULTS.md)、[DoD](docs/DEFINITION_OF_DONE.md)）。Staging project作成・実Googleログイン・ChatGPT/Claude実ホスト・顧客Sheets・Meta実機・決済は未実施です。既存アカウント・本番DBへの変更、投稿・課金・デプロイは行っていません。

## 変更の要点

- **4 → 11テーブル**。元の4テーブルを残し、運用4＋製品計測3を追加。`billing_events`は拡張し、別台帳と二重にしません。
- **5本の追加マイグレーションSQL**。旧SQLはバイト単位で保持。実際のタイムスタンプは公式Supabase CLIで生成します。
- 顧客の鑑定本文・相談全文・出生情報・Sheets内容／ID／トークンは保存しません。`user_readings`は90日間の最小限のリクエスト台帳です。
- 同一`requestId`の再試行は、DBトランザクションで利用回数を二重消費しない設計。別入力でのID再利用は拒否します。
- Threadsの投稿公開は**本文ハッシュへの承認＋公開スイッチ**が必要。結果不明の公開を自動再投稿しません。
- 投稿24/72/168時間の**実際の観測日時**を保存。未取得はNULL、フォロワーはストックとして分離。
- 計測は初期OFF＋ユーザー同意。関心テーマは別同意。撤回時に任意イベント・評価を削除、テーマを消去します。
- 顧客MCPと運営HMAC APIを分離。実決済・署名アダプターは未接続のまま閉じています。

## 最短の引継ぎ手順

1. [AGENTS.md](AGENTS.md)、[UPGRADE.md](docs/UPGRADE.md)、[DoD](docs/DEFINITION_OF_DONE.md)を読む。
2. Node 22.16+で `npm ci`（正規lockfile同梱）。
3. **別の開発／Stagingプロジェクト**と秘密値を用意。Worksの本番を使わない。
4. Docker・公式Supabase CLI（2.120.0で検証）・psqlを用意し、次を実行する。いずれもローカルのみで、リモートDBには接続しない。

```bash
npm run release:check     # migration整合・unit・static・typecheck・build・使い捨てPG・audit
supabase start            # 専用ローカルstack（554xx）
npm run test:db:supabase  # 実SupabaseイメージでSQLスイート
node scripts/e2e-local.mjs  # appをlocalhost:3000で起動後。OAuth 2.1/PKCE/同意/MCP/RLS
```

Stagingへの適用は [検証・デプロイ手順](docs/DEPLOYMENT_AND_TESTS.md) の順（`db push --dry-run` → 承認 → `db push`）。migrationは8本（旧1 + v0.2の5 + forward-fix 2）。

## 配置

```text
app/login, app/oauth/consent       Googleログイン・同意・必要なアカウント操作だけ
app/api/mcp                       顧客向け7ツール
app/api/ops                       運営者専用・HMAC署名付きコマンド
app/api/cron/maintenance           保持期限・Insights収集。投稿は実行しない
src/domain                        純粋な占術・入力検証・指標・署名
src/integrations/threads.ts        Meta接続。書き込みの自動再試行なし
src/lib                           DBトランザクション・運営処理
supabase/migration-templates       5本の追加SQLの原本（hashで生成物と対応）
supabase/migrations                旧履歴＋CLI生成の5本＋forward-fix 06/07
supabase/tests                    RLS・二重実行・課金・KPI・保持期限のSQLテスト
ops/                              運営専用スキル・コマンド例・実験計画
skills/fortune-journal             顧客用スキルのみ
verification/                     実行済み／未実行を分けた記録
```

## P0 / P1 / P2

|段階|利用できるソース機能|有効化条件|
|---|---|---|
|P0 Threads実験|投稿管理、承認公開、過去投稿のページ取込、Insights収集、運営API|Meta権限・実機確認、OPS設定。公開は追加スイッチ|
|P1 プラグイン|数秘術・タロット、割当量、任意計測、評価、エクスポート・削除|Google/MCP OAuth・RLS実機。計測は二重の許可|
|P2 決済|正規化台帳、重複排除、順序制御、MRR・入出金の別集計|業種承認、実署名検証・照合・解約の実装。未完了|

無料3回/ISO週、14日Trial100回/日/占術、Premium200回/日/占術は**商品仮説**です。Trialはログイン時ではなく初回計算時に開始します。利用枠はAIから変更できません。

## 必読

[DB/RLS](docs/DB_RLS_DESIGN.md) · [KPI](docs/KPI_DICTIONARY.md) · [Threads運用](docs/THREADS_OPERATIONS.md) · [データ境界](docs/DATA_BOUNDARIES.md) · [検証・デプロイ](docs/DEPLOYMENT_AND_TESTS.md) · [出典と未確認事項](docs/SOURCES.md)

顧客のAIがSheetsに書いたことも、顧客側の推論コストも、自社サーバーからは確認できません。申告を実測に、NULLを0に、解釈を予測精度に変えないことがこの実装の原則です。
