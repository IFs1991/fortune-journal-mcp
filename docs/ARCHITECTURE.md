# Architecture v0.2

```text
Customer ChatGPT / Claude ── OAuth ──> Vercel /api/mcp ──> Supabase Auth + 11 app tables
           │                               │
           └─ official Google connector    └─ pure TS numerology/tarot, no LLM API
                  └─ customer Sheets (journal text stays here)

Owner agent ── separate HMAC ──> Vercel /api/ops ──> owned Threads account + ops tables
Vercel Cron ── CRON_SECRET ──> maintenance ──> retention + bounded insight snapshots
Approved payment provider ── [NOT CONNECTED] ──> verified normalizer ──> atomic ledger
```

同じコードベースで処理を分離し、常駐workerを足さない。外部I/Oはリクエスト時間内に収める。公開POSTは再送しない。較小規模のhourly cronでP0集計を足すため、初版の「cronなし」方針は改めるが、顧客への通知ジョブは作らない。

## 冪等性

- 計算：user＋UUID＋HMAC fingerprint。raw入力や結果キャッシュなし。DB RPC1回でquotaとmetadataをcommit。
- 課金：provider＋event ID、さらにeconomic key。amountの通貨・単位を明示。状態snapshotは順序を比較。
- 公開：post row lock、本文hash、run lease。外部成功とDBがずれたらunknown。
- 取込／収集：external post ID／run＋snapshot粒度で重複排除。capture_keyはrun削除後も残す。

## 未実装・未検証の境界

SDK/Supabase実接続、依存lockfile/full build、Meta実I/O、Google write E2E、通知宛先、課金approvalと本番adapterは未完了。MCPで返した結果はユーザーが見たという証明でもGoogleへ保存したという証明でもない。

新たなuser_readings/funnelを無制限に増やすのではなく、運用台帳と任意改善計測を分ける。細かなprofiling、匿名tracking、free text、外部LLM生成、admin dashboardは今回の範囲外。
