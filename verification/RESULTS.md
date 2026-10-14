# Verification results — 2026-10-14 / v0.2.0

このファイルは**実行したものだけ**を合格とします。ソース同梱と検証完了は別です。

|検証|結果|範囲|
|---|---|---|
|Node単体テスト|**31 passed / 0 failed**|占術、日付、URL/Origin、署名、指標正規化、課金正規化、mock Threads|
|静的契約チェック|PASS|11表の宣言/RLS、5SQLhash、7MCPツール、無効flags、禁止データの形|
|TS/TSX構文検査|PASS・39 files|外部依存の型チェックではない|
|純粋domain/integration型検査|PASS・9 files|Node型付き。Next/MCP/Supabaseを含まない|
|Shell構文|PASS|test-db.shの構文|
|旧migration保持|PASS|元アーカイブとバイト一致、SHA-256一致|
|JSON構文|PASS|同梱設定・manifest・例|
|PostgreSQL / RLS / 同時実行|**BLOCKED**|Docker/PostgreSQLなし。SQLテストは作成済み・実行できていない|
|公式CLIによる5migration生成|**BLOCKED**|Supabase CLIなし。テンプレートと生成スクリプトを提供|
|フルTypeScript|**BLOCKED**|依存未導入。module/type resolutionエラー。純粋部分の合格で代替しない|
|Next production build|**BLOCKED**|next executable未導入|
|依存install / lockfile|**未完了**|npm registryにDNS接続できず、継承pinの実在・peer互換は未検証|
|実OAuth / Meta / Sheets / 決済 / Vercel|**未実行**|接続設定・認可・審査・別Stagingが必要|

実行コマンド・exit code・日時・環境はresults.json、出力は同名のlog。31件は外部サービスの実機テストではありません。SQLはソースレビューと静的検査のみです。

## 公開前の順番

公式registryで依存pin確認 → 本物のlockfile → full check/build → 公式CLIで5SQL生成 → 使い捨てPostgres fresh/upgrade → 実Supabase RLS/OAuth → 対象AI/顧客Google → 承認済みMeta → 決済別gate。

DB・本番リソース・Threads投稿・契約・秘密値は変更していません。環境がない検証を通ったことにしないでください。
