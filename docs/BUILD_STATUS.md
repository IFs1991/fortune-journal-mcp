# Build status — v0.2 source delivery

このアーカイブは再構築したソース一式であり、本番公開済み製品ではありません。実行した検証は `../verification/RESULTS.md` と同ディレクトリのログで確認してください。

## 実装済みの範囲

11表、5追加SQL、RLS/列GRANT、トランザクション、同意/削除/export、Meta adapter、運営HMAC API、cron、7MCPツール、KPI集計、エージェントルールと受入テスト。

## ブロックしているもの

- npm registryに接続できず、継承済み依存pinのinstall/peer互換検証ができていません。package-lock.jsonは捏造していません。
- full TypeScript / Next buildは依存未導入のため未完了。純粋domainの型検査をfull checkと混同しないこと。
- Docker/PostgreSQL/Supabase CLIがないため、SQL/RLS/並列実行と実migration生成は未実行。5SQLはtemplateとして同梱し、実CLIで生成するスクリプトを添付。
- Google/Supabase OAuth、ChatGPT/Claude、顧客Google Sheets、Threads実API、Vercelデプロイは未実行。
- 決済業種審査・実adapter・解約/照合・法務通知・障害通知destinationは未完了。

## 暗黙の完了扱いを禁止

テストが存在する→合格、MCPが計算した→Google保存成功、顧客LLM費が見えない→無料、snapshotがない→0、コードをzip化した→デプロイ完了、という読み替えはしないでください。
