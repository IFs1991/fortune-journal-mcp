# v0.1 → v0.2 Upgrade

## 提供物

旧`20261014000100_initial_schema.sql`は変更せず、5本の追加SQLを`supabase/migration-templates/`に同梱しています。SQLはスケッチではなく、DDL、制約、RLS、GRANT、RPC、view、保持期限処理を含みます。ただし**実DB未実行**です。

この作業環境には公式Supabase CLIがなく、ネットワークも利用できなかったため、タイムスタンプを捏造せず`prepare-migrations.mjs`を添付しました。元SQLとテンプレートのSHA-256を`migration-manifest.json`で検査し、CLIが作るファイルだけを使用します。

## 5段階

|順番|SQL|役割|
|---|---|---|
|1|01_growth_operations|4運営表、同意項目、投稿変更ガード|
|2|02_product_telemetry_and_billing|3製品表、既存課金表拡張、列権限|
|3|03_transactional_commands|計算＋quota原子性、同意撤回、run lease、公開状態機械|
|4|04_billing_and_kpis|正規化課金、反応率、コホート、MRR、現金、流入、フォロワー差分|
|5|05_retention_and_security|保持期限、未知の公開処理、旧quota RPC無効化|

## 新規環境と既存環境

1. 公式CLIをインストールし`supabase --version`、`supabase migration new --help`を確認。
2. `npm run db:prepare`。**DB接続もSQL適用もしない**。5つの実ファイルと`template-lock.json`をレビュー／コミット。
3. `npm run db:check-prepared`。旧履歴hash・5SQLhash・重複timestampを検査。
4. Docker環境で`npm run test:db`。新規と旧データ入りの2ケースを検証。Authはstubなので実Supabaseも必要。
5. Stagingの対象ID、既存migration履歴、バックアップを確認。CLIの`db push --help`等を読み、dry-runをレビューしてから適用。
6. full typecheck/build→Staging OAuth/MCP→匿名/A/Bユーザー→同時実行→Meta読取り／別途承認したテスト投稿。
7. 本番移行は別承認。旧アプリ受付を停止してDBと新アプリを揃える。公開済みv0.1運用がある場合は停止時間／前方互換方式を別途設計。

**テンプレート生成前のdb pushは旧4表しか作りません。** `release:check`は未生成の状態を拒否します。

## 互換性とロールバック

- v0.2の5段階目で旧`consume_usage`をservice_roleからも撤回します。旧v0.1バイナリへの単純ロールバックは不可。旧アプリと同時に走らせない。
- 既存subscriptionsにverified_atを自動付与しません。旧課金情報は残りますが、利用権限を与えるには実事業者との照合が必要。
- 過去のsignup・投稿反応・初回鑑定を捏造してbackfillしません。初回時刻未確定の旧ユーザーは新規登録コホートと混ぜません。
- 破壊的なdown migrationは同梱しません。データを保ったforward-fix、または承認済みのバックアップ復元を選びます。
- 本番適用済みテンプレートを編集して再生成しない。不一致を検出したら新しい6本目のmigrationを作る。
- SQLの手動直接投入は履歴を壊すため禁止。DBテストの直接投入は使い捨てコンテナ内だけ。
