# MCP communication / performance

方針: 不要な通信・重複DBアクセス・直列処理を減らす。Redis・別サービス・別言語・別DBは入れない。**安全性と整合性を性能より優先**し、Authは省略しない。数値の正本は `verification/perf/*.json`（生データ）。ここはその要約で、測っていない改善は書かない。

## 1. 計測方法

| 項目 | 内容 |
|---|---|
| 環境 | Windows 11（i7-1255U, 12 threads）、Node 22.22.2、Supabase CLI 2.120.0 ローカルstack（Docker: Supabase Postgres 17 + GoTrue + PostgREST + Kong）、`next start`（production build）。すべてloopback |
| 負荷 | 1ユーザー逐次、ツールごとに warmup 5 + n=100。DCR+PKCE+同意で得た実アクセストークン。Premium fixture（ローカルのみ） |
| クライアント側 | `scripts/bench-mcp-local.mjs`。HTTP往復の壁時計、p50/p95は nearest-rank |
| 外部通信回数 | Kongのアクセスログを計測ブロック前後で数える（アプリの計測と独立） |
| サーバー側 | `MCP_TIMING_LOG=true` の `FJ_MCP_TIMING`（`src/lib/perf.ts`）。`db_ms` は応答経路上のPostgREST時間の合計 |
| DB単体 | `scripts/bench-db.sh <repo> "<status SQL>" <out>`: 使い捨てPG 17で `pgbench`（結果 `verification/perf/v030_db_microbench.txt`）。100ユーザー、Premium、各2000回（heavyは1000回） |

**限界**: ローカルGoTrueの `/auth/v1/user` が p50 約70–100ms・p95 約140–200ms と遅く揺らぐため、エンドツーエンドの差はAuthの揺らぎに埋もれる。Vercel↔Supabase間の実RTTとコールドスタートは未測定（BLOCKED: Staging未作成）。

## 2. 認証: 毎回 `getUser()` を維持

`getClaims()`（ローカルJWKS検証）は p50 約1ms だが、セッション失効後・ユーザー削除後もトークンを受理した（`verification/perf/auth_probe.json`）。失効の即時性を失うため不採用。採用した削減は「拒否だけを前倒しする事前チェック」1点: 期限切れ・他issuer・client_idなしは Auth 0回で401（`verification/perf/expired_token_after.json`）。受理には必ず `getUser()` と検証済みuser IDとの照合が必要。

## 3. 1ツール呼出しあたりの通信（現在）

| ツール | Auth | DB（応答経路） | 備考 |
|---|---|---|---|
| get_account_profile | 1 | 0 | 計測ONでも接続イベントは応答後（`after()`） |
| get_access_status | 1 | 1 | `fj_access_status`（tier判定もDB内） |
| get_journal_schema | 1 | 0 | |
| calculate_numerology / draw_tarot | 1 | 1 | `fj_record_calculation` 1回（replayも同じ） |
| submit_reading_feedback / report_journal_action | 1 | 計測OFF 0 / ON 1 | |
| 401（期限切れ・他issuer等） | 0 | 0 | |

ホストが占いの前に `get_account_profile` → `get_access_status` を呼ぶと HTTP 3・Auth 3。ツール説明・サーバーinstructions・顧客Skillで「計算ツールを直接呼ぶ」よう指示している（実ホストが従うかは BLOCKED）。

## 4. v0.3.0 リファクタ前後（2026-10-16、分析OFF、n=100）

Before = `3de9f3c`（PR #1 のコード + 整形のみ）、After = このブランチ。同じマシン・同じローカルstack・同じ手順。

| tool | Auth | DB (Kong) | client p50 ms | client p95 ms | server db_ms p50 | server db_ms p95 |
|---|---|---|---|---|---|---|
| get_account_profile | 1→1 | 0→0 | 109.2→101.8 | 170.7→151.1 | 0→0 | 0→0 |
| get_access_status | 1→1 | 1→1 | 99.1→92.4 | 191.6→139.4 | 13.4→6.4 | 32.5→9.2 |
| get_journal_schema | 1→1 | 0→0 | 84.2→87.4 | 154.4→133.5 | 0→0 | 0→0 |
| calculate_numerology | 1→1 | 1→1 | 98.9→90.3 | 165.2→156.4 | 8.9→7.6 | 20.5→13.7 |
| draw_tarot | 1→1 | 1→1 | 127.9→84.6 | 234.5→128.9 | 11.0→7.6 | 21.8→11.6 |
| draw_tarot（replay） | 1→1 | 1→1 | 94.9→92.8 | 176.0→123.9 | 7.7→7.3 | 15.6→10.4 |
| submit_reading_feedback | 1→1 | 0→0 | 90.8→90.8 | 162.8→196.3 | 0→0 | 0→0 |
| report_journal_action | 1→1 | 0→0 | 102.7→92.2 | 184.1→179.0 | 0→0 | 0→0 |

成功率は同一（OFFの feedback/report は仕様どおり `OPTIONAL_ANALYTICS_DISABLED`、他は100%）。

DB関数単体（pgbench、ms、2回ずつ交互に実行）:

| シナリオ | Before p50 / p95 | After p50 / p95 |
|---|---|---|
| access status | 0.21 / 0.47、0.12 / 0.41 | 0.12 / 0.49、0.13 / 0.30 |
| replay（同一drawId） | 1.16 / 2.76、1.09 / 1.93 | 1.27 / 2.40、1.19 / 2.38 |
| 新規（当日0–40回目） | 1.29 / 2.27、1.38 / 2.79 | 1.51 / 3.29、1.61 / 3.45 |
| 新規（当日150–190回目） | 1.66 / 3.09、2.02 / 3.85 | 1.94 / 4.83、1.52 / 2.43 |

**評価**
- 往復回数は変わらない（増やしていない）。Kongで確認。
- DB関数の処理時間は誤差の範囲で同等。新規計算はカウンタ更新の代わりに台帳を数えるため p50 で +0.1〜0.3ms 程度の可能性があるが、ばらつき内。
- サーバー側 `db_ms` は After が小さいが、原因は切り分けていない（Supabase clientのプロセス内再利用、Before のstackは過去のE2Eデータが残った状態・After は `db reset` 直後、の両方が交絡）。**性能改善とは主張しない。** エンドツーエンドの差はAuthの揺らぎの範囲。
- 運営側: レポートの独立した6読取りを並列化（逐次6往復 → 待ち時間1往復分）、定期snapshotの対象確認を投稿ごとの問合せから1回に変更（N+1解消）。いずれもローカルで未計測（Threads無効のため）。

PR #1（2026-10-15）の通信削減（draw_tarot / get_access_status 2→1、profile計測の応答経路外し）の測定は `verification/perf/before_*.json` / `after_*.json`。

## 5. 計測の仕組み

`src/lib/perf.ts`: AsyncLocalStorageでリクエスト単位に Auth/PostgREST の回数と時間を集計（Supabase clientの `global.fetch` を差し替え。リクエスト外は素通し）。`MCP_TIMING_LOG=true` のときだけ1呼出し1行 `FJ_MCP_TIMING {tool, ok, error_code, total_ms, auth_ms, db_ms, calculation_ms, outbound_auth_calls, outbound_db_calls}`。入力・ユーザーID・トークン・結果は出さない。DB書込みなし。

## 6. 未検証

- Vercel/実Supabaseでの往復時間・コールドスタート、`after()` のVercel上の挙動（BLOCKED）。打ち切られても失うのは任意の `mcp_connected` イベントだけ。
- 実ホストが事前呼出しを省くか（BLOCKED）。
