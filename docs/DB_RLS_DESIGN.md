# Database / grants / RLS v0.2

PostgreSQL 17での検証を想定（security_invoker view / NULLS NOT DISTINCTにPG15+が必要）。Supabase Auth標準表は自作しません。アプリ表は11、追加の独自プロフィール・巨大占い知識DBはありません。

## データ辞書

|Table|粒度・主キー|内容と重要制約|
|---|---|---|
|user_access|1ユーザー|Trial開始/終了、停止、任意同意/関心同意/版/更新日、初回計算日時。ログイン・同意だけではTrial開始しない|
|subscriptions|1事業者契約|provider＋外部契約ID一意。ユーザーbinding、状態、有効期限、署名確認日時、料金minor/currency/exponent/interval。状態と料金は別|
|usage_counters|user＋feature＋bucket＋期間|Free ISO週、Trial/Paid UTC日。権限はサーバーが決定。UI書換え不可|
|billing_events|provider＋event ID|正規化された検証済み課金通知。economic_keyも一意。生Webhook非保存。ユーザー削除時は参照NULL|
|fortune_posts|内部UUID|運営者投稿本文、ハッシュ、固定分類、prompt/experiment/variant、外部ID、承認・公開状態。公開済み本文は不変|
|post_metric_snapshots|投稿＋観測|24/72/168目標または手動/現在backfill。実観測日時、API版、lifetime各指標。欠測NULL|
|account_metric_snapshots|capture＋account＋metric＋period|LONG形式。followersはpoint-in-time、他はday/range。capture_keyはrun削除後も保存して一意性を保つ|
|automation_runs|task＋idempotency_key|取得リース、状態、試行数、所要時間、安全なerror。モデル/費用はprovenanceつき、未観測NULL|
|user_readings|user＋request UUID|計算済み運用メタデータ、秘密HMACfingerprint、占術版、対象日、tier、quota結果。本文なし。任意topicだけ別同意|
|funnel_events|user＋dedupe_key|signup、接続、計算、本人申告の保存/振返り。観測源と流入の証拠を区別。匿名追跡IDなし|
|reading_feedback|user＋reading|有用性1–5、主観的一致の固定分類、任意振返り日。複合FKで他人のreadingに紐付け不可|

## 権限表

|Resource|anon|authenticated|service_role|
|---|---|---|---|
|user_access / subscriptions / usage_counters|なし|自分の行SELECTのみ|backend read/write|
|user_readings|なし|自分の許可列SELECTのみ。fingerprint等は不可|backend read/write|
|reading_feedback|なし|自分の行SELECTのみ|backend read/write|
|funnel_events / billing_events|なし|直接アクセス不可。本人エクスポートAPIのみ|backend read/write|
|4運営表|なし|なし|backend read/write|
|fj_* RPC|なし|なし|明示許可したRPCだけ|
|集計views|なし|なし|SELECT|
|旧consume_usage|なし|なし|v0.2最終段階で不可|

全表にRLSを設定します。ただし**service_roleはRLSを迂回**します。顧客向けAPIは検証済みAuth IDを所有者条件に使い、DBへ渡すuser_idをユーザー入力から取らないこと。owner SQLを全顧客MCPに公開しないこと。

## 原子性と再試行

`fj_record_calculation`がuser_access行をロックし、停止→権限→既存request→quota→metadata→同意イベントを一つのトランザクションで処理します。同一user/request/入力ならquotaを増やしません。別入力のID使い回しは拒否。Trial切れ後の有料専用機能や停止中は再試行も拒否します。

結果本文は保存しないため、計算コードは純粋・再現可能に保つ必要があります。90日経過／鍵版変更後まで無期限のexactly-onceを約束しません。新UUIDでの呼び直しは新処理です。`remainingAtCompletion`は初回完了時の残数で現在残数ではありません。

Threads公開は、承認ハッシュ確認→postロック＋run獲得→外部公開→確定。DBとMetaを一つのトランザクションにはできません。タイムアウト／確定失敗はunknownとして人または承認された照合手順へ戻します。

## 保持期限

運用readings・quota・任意イベント90日、feedbackはreadingと連動。成功／失敗run90日、投稿/アカウントsnapshots400日。公開unknownは自動削除しません。初回計算日時・同意設定はアカウント期間中保持します。

Vercelの認証付きmaintenanceがpurgeを日次で呼びます。ジョブ設定の存在は実稼働の証拠ではありません。直近実行・失敗通知を本番で検証すること。保持日数は提案値で、法務・個人情報通知の確定後に有効化してください。

課金履歴の法定保持は国・事業者に依存するため自動purgeしません。user_idをNULLにしても外部IDで結合可能なら匿名化ではありません。保存方針・DSAR・決済事業者側の削除範囲を課金開始前に確定します。

## テスト

`supabase/tests/`は匿名/A/B、列権限、禁止更新、RPC否認、同意撤回、公開unknown、重複経済イベント、古い課金状態、異通貨、snapshot、保持期限を検査します。`scripts/test-db.sh`は10並列quotaと10並列同一requestも検査。**付属していることと、この環境で通ったことは別です。verificationを確認してください。**
