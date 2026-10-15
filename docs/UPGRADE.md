# v0.1 → v0.2.1 Upgrade

## 提供物

旧`20261014000100_initial_schema.sql`は変更せず、公式Supabase CLI 2.120.0の `migration new` でタイムスタンプを付けた追加migrationを `supabase/migrations/` に置いた。元テンプレート（`supabase/migration-templates/`）とのhash対応は `supabase/template-lock.json`、forward-fixは `supabase/migration-manifest.json` の `forwardFixes` に登録済み。

## 適用順（9本）

|順番|migration|役割|
|---|---|---|
|0|20261014000100_initial_schema|v0.1（4表）|
|1|20261014160916_fj_v02_01_growth_operations|4運営表、同意項目、投稿変更ガード|
|2|20261014160919_fj_v02_02_product_telemetry_and_billing|3製品表、既存課金表拡張、列権限|
|3|20261014160922_fj_v02_03_transactional_commands|計算＋quota原子性、同意撤回、run lease、公開状態機械|
|4|20261014160925_fj_v02_04_billing_and_kpis|正規化課金、反応率、コホート、MRR、現金、流入、フォロワー差分|
|5|20261014160928_fj_v02_05_retention_and_security|保持期限、未知の公開処理、旧quota RPC無効化|
|6|20261014162204_fj_v02_06_privacy_registration_forward_fix|`fj_set_privacy` が service_role で読めない `auth.users` を参照していた不具合の修正（登録時刻はAuth検証済みuserからbackendが渡す）|
|7|20261014164844_fj_v02_07_fk_covering_indexes|purgeのcascadeが子表を全走査しないためのFK被覆index|
|8|20261015062212_fj_v02_08_single_roundtrip_mcp|MCP往復削減: `fj_record_calculation` が既存tarot抽選を自分で照合（日付を跨いだ再試行・Trial終了後の同一再試行をreplay）、`fj_access_snapshot`（get_access_status用の読み取り専用RPC）|

## 新規環境と既存環境

1. `supabase --version`（2.120.0で検証）、`supabase migration new --help` を確認。
2. `npm run db:check-prepared` — 旧履歴hash・テンプレートhash・forward-fix hash・未登録migration・重複timestampを検査（DB接続なし）。
3. `npm run test:db`（使い捨てPG、fresh + v0.1データ入り）と `npm run test:db:supabase`（実Supabaseイメージ）。
4. Stagingは [DEPLOYMENT_AND_TESTS.md](DEPLOYMENT_AND_TESTS.md) §3（link → migration list → db dump → `db push --dry-run` → 承認 → `db push`）。
5. 本番移行は別承認。旧アプリ受付を停止してDBと新アプリを揃える。公開済みv0.1運用がある場合は停止時間／前方互換方式を別途設計。

## 互換性とロールバック

- 05で旧`consume_usage`をservice_roleからも撤回する。旧v0.1バイナリへの単純ロールバックは不可。旧アプリと同時に走らせない。
- 06は旧4引数 `fj_set_privacy` をDROPして5引数版（第5引数 `p_registered_at` DEFAULT NULL）を作る。v0.2.0のアプリは4引数呼び出しのため動くが、登録cohortは記録されない。v0.2.1アプリと組で適用する。
- 08は `fj_record_calculation` を同じ引数で置換し、`fj_access_snapshot` を追加する。**08を先に適用してからアプリを更新する**（逆順だと新アプリの `get_access_status` が `ACCESS_TEMPORARILY_UNAVAILABLE`、日付を跨いだtarot再試行が `IDEMPOTENCY_CONFLICT` になる）。08適用後も旧v0.2.1アプリはそのまま動く（旧アプリは元の抽選日を渡すため結果は同じ）。
- 既存subscriptionsにverified_atを自動付与しない。利用権限を与えるには実事業者との照合が必要。
- 過去のsignup・投稿反応・初回鑑定を捏造してbackfillしない。
- 破壊的なdown migrationは同梱しない。データを保ったforward-fix、または承認済みのバックアップ復元を選ぶ。
- 適用済みmigrationを編集して再生成しない。不一致を検出したら新しいforward-fixを作り、manifestに登録する。
- SQLの手動直接投入は履歴を壊すため禁止。DBテストの直接投入は使い捨てDB／ローカルstack内だけ。
