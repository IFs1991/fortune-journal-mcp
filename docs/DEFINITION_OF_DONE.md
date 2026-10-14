# Definition of Done — v0.2

**チェックは証拠のあるものだけ。テストファイルの存在はテスト合格ではない。** 状態はverification/RESULTS.mdが正本。以下は公開受入基準で、全完了を宣言していない。

## G0 Source delivery

- [x] 既存v0.1 migrationを変更せず、追加5段階SQLとhash manifestを用意。
- [x] P0/P1/P2データ境界、11表の制約/索引/RLS/GRANTを実装。
- [x] 顧客MCPと運営API、本人任意同意と関心同意、data export/revokeを分離。
- [x] customer journal/出生/Google token/自由文feedbackを保存対象から除外。
- [x] テスト、runbook、エージェント指示、無効化flags、事実/未検証を同梱。

## G1 Dependency / build (release blockers)

- [ ] 実npm registryで全pinの存在・SDK peer互換・脆弱性を照合。
- [ ] レビュー済みlockfileを作成、npm ciが再現可能。
- [ ] full TypeScript、Next production build、Node/Vercel runtime smokeがPASS。
- [ ] PR CIがunit / database / buildに成功。第三者Action/コンテナのpinを確認。

## G2 Database (release blockers)

- [ ] 公式CLIで5テンプレートをmigration化、db:check-preparedがPASS。
- [ ] 新規/既存v0.1データ入りPGで全migration PASS、旧データ保持。
- [ ] 匿名・A・Bの読取/列権限/不正更新/課金/運営RPCのnegative tests PASS。
- [ ] 同一request10並列→1quota、異なるrequest10並列→Free上限3、rollbackの原子性を確認。
- [ ] 署名未検証・重複経済事象・逆順状態・通貨別MRR/cashが期待どおり。
- [ ] 90/400日purge、capture_key一意性、FK削除、同意撤回、本人exportがPASS。
- [ ] 実SupabaseのData API公開設定/権限/advisorsを確認。Docker Auth stubだけで完了しない。
- [ ] バックアップ/復元、移行停止時間、旧アプリ互換性を確認。

## G3 Customer/MCP (release blockers)

- [ ] Googleだけのログイン。意図しないpassword/email signupなし。
- [ ] 両対象hostでOAuth discovery/PKCE/同意拒否/refresh/revoke/expiry/削除後を確認。
- [ ] 課金/Trial判定はサーバーのみ。同意しただけでTrialを始めない。
- [ ] 同一request再試行・別入力conflict・日付越えtarot・Free制限が実機でPASS。
- [ ] 顧客本人Sheetsへの作成/追記/再参照。権限なし/承認拒否/重複行/式注入/他人のsheetを確認。
- [ ] MCP完了をSheets保存成功と表示しない。feedbackは明示選択、計測拒否でも基本機能が動く。

## G4 Threads P0

- [ ] 事業者所有accountのみ。token権限とAPI版を確認。
- [ ] 過去投稿pagination重複・欠測・現在backfillが期待どおり。
- [ ] 実24/72/168h観測と24–26h比較窓を確認。API missingを0にしない。
- [ ] followersを期間metricと別取得し、endpoint差分・欠測を検証。
- [ ] 承認hash不一致で公開拒否、同時公開を一つに、timeout/unknownを自動再公開しない。
- [ ] cron実行と失敗/収集停止/unknownを通知するdestinationを確認。
- [ ] 運営費用の外部申告/推定/観測不能を分離。

## G5 Business / payments / policies

- [ ] プライバシー通知、同意文、保存期間、export/delete連絡先、規約を公開。
- [ ] Threads投稿内容/AI表示/ホストの掲載と課金導線ポリシーを確認。
- [ ] 決済業種承認と実adapter、顧客解約、署名検証、照合・返金・チャージバックを確認。
- [ ] 更新率は期日を過ぎた母数で測定し、初回/継続を区別。
- [ ] 費用・税・手数料のない状態で粗利/LTVを実測と称さない。

## Go / no-go

P0非公開の運営テスト、P1無料公開、P2課金公開は別gate。課金だけ未完了なら課金を無効にして他の完成gateを満たす範囲で進める。OAuth・RLS・full build未完了のまま一般公開しない。
