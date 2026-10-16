# Claude Code実装指示｜Fortune Journal v0.2 → Deploy-Ready

あなたはシニアのTypeScript/Next.js/MCP/Supabase/Vercelエンジニア兼セキュリティレビュー担当です。このリポジトリを、実測証拠に裏付けられた「Stagingデプロイ可能状態」まで修復・完成してください。提案だけで終わらず、許可されたローカルファイルの実装修正、テスト、ドキュメント更新まで行ってください。**この依頼は本番公開の承認ではありません。**

## 0. 最初に必ず確認する現状

対象はこの作業ディレクトリに展開された `fortune-journal-mcp-v0.2-growth-2026-10-14.zip` のルート `fortune-journal-mcp/`。`README.md`、`AGENTS.md`、`Agent.md`、`CLAUDE.md`、`docs/DEFINITION_OF_DONE.md`、`docs/UPGRADE.md`、`docs/DB_RLS_DESIGN.md`、`docs/DATA_BOUNDARIES.md`、`docs/BUILD_STATUS.md`、`verification/RESULTS.md`、`supabase/migration-manifest.json` を最初に読み、`git status` と構造・差分を確認してください。

このアーカイブは**ソーススターターであり、実機検証済み製品ではない**。既知の未完了は、npm依存pinの実在・互換性検証、正規 `package-lock.json`、full TypeScript/Next本番ビルド、Supabase公式CLIでの追加5 migration生成、実PostgreSQL/RLS/同時実行テスト、Supabase OAuth 2.1＋Googleログイン、ChatGPT/Claude MCP・Google Sheets E2E、Meta Threads実API検証、決済事業者の承認とWebhook実装です。過去の単体31件PASSを外部E2E合格と読み替えないこと。

## 1. 変更不可能なプロダクト原則

- 対象商品は海外向け **Fortune Journal**。顧客のAI（ChatGPT/Claude）が対話と記録を行い、**顧客自身のGoogle Sheets**に鑑定・生活日誌を保存する。自社MCPは数秘術・タロット等の計算と最小限の機能管理だけ。
- **TypeScript / Next.js / Vercel / Supabase**を維持。Railway、Rust、別バックエンド、独自LLM推論、Redis、CMS、巨大管理画面は追加しない。フロントはGoogleログイン、MCP同意、法令上必須のアカウント・プライバシー操作に限定する。
- 自社DBに出生日時・場所、相談全文、鑑定本文、恋愛/生活記録、顧客Google SheetsのID/URL/内容/トークンを保存しない。ログ・トレース・エラーにも混入させない。Google Drive/SheetsへのOAuth権限を自社では要求しない。
- Supabaseの既存11テーブルを必要に応じて改善する。ただし、増表より簡素化を優先。ユーザーの関心・任意フィードバックは**別々の明示同意**がなければ記録しない。推論コストやSheets保存成功は自社で観測していない限り推定・実績と称さない。
- 顧客MCPと運営用 `/api/ops` は完全分離。顧客に運営・課金更新・投稿実行・任意SQLを公開しない。
- 既存の **Tiramisu Works のSupabase / Vercel / GitHub / API keys / DB**には一切触れない。別プロジェクト、別認証、別secretを前提とする。
- `/api/billing/webhook` は決済事業者未確定につき**501 fail-closed**を維持。ダミー署名、偽Premium付与、成功扱いは禁止。一般公開や販売開始を勝手に実行しない。

## 2. 作業順序（途中で止めず、実行できる範囲を完了する）

### Phase A: 技術監査と再現可能ビルド
1. ファイル横断でimport/export、Next route handler、MCP handler、型、実行時env、E2E設計、CI、依存の脆弱性・互換性を監査。重大度 `P0/P1/P2` で修正順を短く提示してから修正。
2. 公式npm registry/各SDKの現行ドキュメントで実在する互換バージョンを確認し、必要最小限のpin変更、正式な`package-lock.json`生成。`npm ci`を新規環境で再現。`npm run test`、`check:static`、`typecheck`、`build`、`npm audit` を実行し、失敗は根本原因から直す。バージョンを根拠なく最新化しない。秘密情報を表示しない。
3. `AGENTS.md`/`CLAUDE.md`/`Agent.md`の矛盾を統一し、CIでリグレッションを検出する。E2E以外は原則自動化。

### Phase B: Supabaseマイグレーション／RLS／整合性
1. **旧 `supabase/migrations/20261014000100_initial_schema.sql` を絶対に編集しない**。manifest hashを照合。`supabase/migration-templates/01〜05`は公式Supabase CLIの`migration new`でタイムスタンプ付与し、準備済みSQLとlockを生成・レビュー。既にDB適用されたmigrationは書き換えずforward-fixを使う。実行前に現行CLIの`--help`でコマンド確認。
2. fresh DB と v0.1データ入りDB の2パターンでmigration、参照整合性、indexes、列権限、RLS、RPC、データ保持、explain/性能の要点を検証。
3. `anon`、本人A、他人B、service roleで**否定テスト**。他人のレコードは不可、本人でも契約・無料枠・trial・投稿・課金イベントを書き換えられない。`SECURITY DEFINER`は極力使わず、必要なら固定search_path・権限限定・悪用試験を必須とする。
4. `requestId`の同一入力リトライは同一結果・二重quota消費なし、異入力でID衝突なら拒否。10件程度の同時実行と上限境界を、実Postgresのトランザクションで検証。
5. `billing_events` の署名済みイベントを想定した重複・順序逆転・返金・複数通貨・失効判定を検証。ただし実決済は有効化しない。
6. 初回獲得、D7、初回課金、課金更新、Threads反応率の定義に分母・対象期間・欠測区分があることを確認。NULLを0にせず、利用クライアントを獲得チャネルと誤認しない。

### Phase C: OAuth・MCPセキュリティ／ツール整備
1. Supabase AuthのGoogleログインと**別の**OAuth 2.1 MCP承認フローを現行公式仕様と照合。`/oauth/consent`のclient情報・scope確認、approve/deny、戻りURLのopen redirect対策、CSRF/PKCE、refresh/revoke、JWTのiss/aud/exp/署名とresource/client binding、401 `WWW-Authenticate` discoveryを検査。UIは最小限でよい。
2. Vercelの`mcp-handler`・使用するMCP SDKの**現行APIに合わせて**`/api/mcp`を実装・検証。ステートレス、適切なHTTPレスポンス、tools/listとtools/call、認証エラー、ツールスキーマと出力schema、ホスト互換性をMCP Inspector等で確認。
3. Google Sheetsは**顧客側の別コネクタ**で扱う。自社MCPが「保存した」と虚偽返答しない。Sheetテンプレートには鑑定作成日/対象期間/方式/結果版/本人の実生活記録を分離し、formula injection、重複記録、ユーザーが連携拒否した場合を検証。AI連携側の未自動化部分は明示。
4. FREE/14日Trial/Premiumの判定はサーバー側で行い、トライアルは初回計算時のみ開始。課金未接続時のPremiumの偽付与や自己申告による昇格を禁止。

### Phase D: Threads・運営エージェント・低保守化
1. 既存のP0運用・P1製品計測・P2決済を分離し、デフォルトは**全て安全側OFF**。Threadsの投稿は内容ハッシュ承認・公開フラグを要する。曖昧な公開結果を勝手に再投稿しない。
2. Threadsの投稿ID・実測スナップショット24/72/168h・フォロワー推移・オートメーションログ、同意済みのファネル・閲覧テーマの整合性をテスト。Metaの権限/API版未確認はBLOCKEDにする。
3. 保持期限・同意撤回・データexport/delete・エラー通知の最小動作を確認。管理画面を足す代わりにAIエージェント用の**read-only優先のCLI/runbook**を整える。無意味なCron/二重運用基盤は増やさない。

### Phase E: デプロイ・プリフライト
1. **Supabase MCP・Vercel MCPが利用可能ならread-onlyで**接続、対象organization/project、地域、環境、現在のDB schema/migration履歴/設定を照合する。未設定なら必要な手順だけを明示する。サービス名で推測して既存Worksの対象を選ばない。
2. `.env.example`と実際のenv参照を突き合わせ、Staging設定一覧（Google provider、OAuth server、公開URL、redirect allowlist、asymmetric signing keys、DB権限、Vercel project、cron署名、秘密鍵分離）を完成。**秘密値の貼り付けやログ表示を要求せず**、Dashboard/Secret Storeで管理。
3. `docs/DEPLOYMENT_AND_TESTS.md`にStagingの適用順、`db push --dry-run`等の正しい現行コマンド、DBバックアップ、rollback/forward-fix、Vercel preview、health/MCP/OAuth/Google Sheet E2E、観測と停止条件を明記。
4. Supabase migrationのremote適用、Vercel deploy、Google/Meta認可変更、外部投稿、課金、本番リリースは**勝手に実行しない**。Stagingでも対象project ID・予定変更・リスク・ロールバックを提示して**明示承認後**に行う。今回はDeploy-Readyまでがゴール。ローカルのファイル修正/テストは承認不要。
5. `npm run release:check`（必要なら改善）とCIが実際に検証できること。ビルドを通すために認証・RLS・重要テストを無効化しない。

## 3. 完了条件と最終報告（必須）

既存DoDをアップデートし、各項目を **PASS / FAIL / BLOCKED / NOT RUN** で、検証コマンド・環境・結果・証拠ファイルに結び付ける。静的grepだけで実DBテストPASSと記載しない。外部接続が利用不能な場合は、無理にシミュレーションで埋めず、残りの操作手順と実行可能なテストを提供。

最終報告の形式：
1. **変更概要**（変更ファイル・主要なバグ修正・依存バージョン）
2. **検証表**（npm ci / tests / typecheck / build / Docker+Postgres / RLS / OAuth / MCP Inspector / Google Sheets / Threads / CI）
3. **Security差分**（tenant isolation、secret、OAuth、quota、署名、プライバシー、権限）
4. **DB移行計画**（migration順、dry-run/backup、rollback不能箇所、適用先の確認方法）
5. **Staging Deploy手順**（Supabase MCP/Vercel MCPまたは正式CLIでの操作、承認を要する箇所）
6. **Go/No-Goと残ブロッカー**（曖昧に「完成」としない）
7. **更新した`AGENTS.md`・`CLAUDE.md`・DoD・Runbook・`verification/RESULTS.md`**へのパス

**優先順位はセキュリティ／DB整合性／認証／ビルド＞計測の精度＞ドキュメント＞追加機能。** 占術や画面を増やさず、低保守で追跡可能な最小構成を完成させてください。作業はブロッカーを報告するだけで終わらせず、ローカルで修正可能な問題をすべて解消してから最終報告すること。
