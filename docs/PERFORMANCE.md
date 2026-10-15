# MCP communication / performance (unreleased, on top of v0.2.1)

目的は「不要な通信・重複DBアクセス・直列処理を減らす」こと。SDK刷新・新インフラ（Redis、別サービス、別言語）はしない。**安全性と整合性を性能より優先**し、同等の安全性を示せない変更は採用しない。
実測値の正本は `verification/perf/*.json`（生データ）。ここに転記した数値はその要約。

## 1. 計測方法と環境

| 項目 | 内容 |
|---|---|
| 環境 | Windows 11（i7-1255U, 12 threads）、Node 22.22.2、Supabase CLI 2.120.0 ローカルstack（Docker: Supabase Postgres 17 + GoTrue OAuth 2.1 + PostgREST + Kong）、`next start`（production build）。すべてloopback |
| 負荷 | 1ユーザー逐次。ツールごとに warmup 5 + **n=100**。新規OAuthクライアント（DCR+PKCE+同意）で取得した実アクセストークン。Premium fixture（ローカルのみ）で上限を避ける |
| クライアント側 | `scripts/bench-mcp-local.mjs`。HTTP往復の壁時計時間、p50/p95は nearest-rank |
| 外部通信回数 | ローカルKongのアクセスログを計測ブロック前後で数える（アプリの計測に依存しない独立した数え方） |
| サーバー側 | `MCP_TIMING_LOG=true` の `FJ_MCP_TIMING` 行（`src/lib/perf.ts`）。`auth_ms`/`db_ms` は各呼出しの合計、`total_ms` は壁時計（並列時に加算しない） |
| 比較 | Before = 計測だけを入れた commit（挙動は main と同一）、After = 本変更。同じマシン・同じstack・同じ手順 |

**ローカル計測の限界**: ローカルGoTrueの `/auth/v1/user` 自体が p50 約100ms・p95 約150–250ms（GoTrueの自己申告 duration でも 100–300ms）と遅く揺らぐ。一方 PostgREST 1往復は約5–9ms、アプリ処理は約5ms、計算は0.2ms未満。したがって**エンドツーエンドの差はAuthの揺らぎ（±10%程度）に埋もれる**。DB削減の効果は `db_ms`（応答経路上のDB時間）で評価する。Vercel↔Supabase間の実RTT・実GoTrueの速度は未測定（Staging未作成のため BLOCKED）。

## 2. 認証（Phase B）: `getUser()` を維持

現行: `verifyOAuthBearer()` が毎リクエスト `auth.getUser(jwt)`（GoTrue `/auth/v1/user`）でセッションとユーザーの存続を確認し、その後 issuer/aud/role/sub/client_id/exp を検証する。

`scripts/probe-auth-verification.mjs`（ローカル、ES256署名、JWKSはプロセス内キャッシュ）の実測 → `verification/perf/auth_probe.json`:

| | getUser（ネットワーク） | getClaims（ローカルJWKS検証） |
|---|---|---|
| p50 / p95（n=100） | 108.85 / 158.35 ms | 0.83 / 1.35 ms |
| 有効なトークン | 受理 | 受理 |
| **セッション失効後**（接続解除・サインアウト相当） | **拒否** | **受理** |
| **ユーザー削除後** | **拒否**（user_not_found） | **受理** |

| 案 | Auth往復 | 失効反映 | トークン漏洩時 | 保守 | 判断 |
|---|---|---|---|---|---|
| A. 全リクエスト `getUser()` | 1/リクエスト | 即時（E2E: revoke直後・削除直後に401） | 失効させれば即停止 | 現状のまま | **採用** |
| B. ツール種別でローカル/オンライン併用 | 一部0 | ローカル側は最大 `jwt_expiry`（3600秒）遅延 | 失効後も最大1時間は一部ツールが使える | JSON-RPC本文を認証前に解釈する分岐、ツールごとに保証が異なる | 不採用（保証が弱まる。get_account_profileもユーザーIDを返す） |
| C. ローカル署名検証＋DB側でセッション確認 | 0（DB 1回に統合） | 即時にできる可能性 | 同等にできる可能性 | `auth.sessions`/`auth.users`（内部スキーマ）を読む SECURITY DEFINER 関数が必要。service_role は auth スキーマを読めない（migration 06 の原因）。GoTrue内部仕様への結合・静的契約（DEFINER禁止）違反 | 不採用（同等性を証明できず保守負担が大きい） |
| （参考）getUser結果の短期キャッシュ | <1 | TTL分遅延 | TTL内は失効後も通る | 小 | 不採用（同等でない） |

採用した安全な削減は1点のみ: **拒否だけを前倒しする事前チェック**。未検証payloadの issuer / aud / role / sub形式 / client_id / exp が不正なら `getUser()` を呼ばずに401。受理には必ず `getUser()` と検証済みuser IDとの照合が必要なので、認証強度は変わらない。期限切れトークン20件で Kong上のAuth呼出し0件・全401（`verification/perf/expired_token_after.json`。変更前は各1往復）。

MCP/OAuth適合性: 401 + RFC 9728 `resource_metadata`、PRM、issuer束縛、client_id必須は変更なし（E2E）。SupabaseのOAuthトークンは `aud=authenticated` で resource固有audがないため、専用projectを前提とする点も従来どおり（SECURITY.md）。

## 3. 通信経路の棚卸し（Phase A）と変更

1回のMCPツール呼出し = ホスト→アプリ HTTP 1往復（stateless、`initialize` 不要）。表はアプリ→Supabaseの外部通信（Kongで実測）。

| ツール | Auth（Before→After） | DB（Before→After） | 直列処理（Before） | 変更 |
|---|---|---|---|---|
| get_account_profile | 1→1 | 分析OFF 0→0 / ON 1→**1（応答後に実行、応答経路0）** | 計測RPCを待ってから応答 | `next/server` `after()` へ移動 |
| get_access_status | 1→1 | **2→1** | `user_access` → `subscriptions` | `fj_access_snapshot` 1回。判定は従来どおりTSの `resolveEntitlement` |
| get_journal_schema | 1→1 | 0→0 | — | なし |
| calculate_numerology | 1→1 | 1→1 | — | なし（増えていないことを確認） |
| draw_tarot（新規/再試行） | 1→1 | **2→1** | `user_readings` 照合 → `fj_record_calculation` | 照合をRPC内へ（migration 08） |
| submit_reading_feedback | 1→1 | OFF 0→0 / ON 1→1 | — | なし |
| report_journal_action | 1→1 | OFF 0→0 / ON 1→1 | — | なし |
| 401（期限切れ・他issuer等） | **1→0** | 0→0 | — | 事前チェック |

コールドスタート: Supabaseクライアント生成は0.1ms未満（測定）で、往復の削減対象ではない。`createMcpHandler` はモジュールスコープ。Vercel上のコールドスタートは未測定。

### ホスト側の呼出し（Phase D）

占いの前に `get_account_profile` → `get_access_status` → `draw_tarot` と呼ばれると、Before で HTTP 3・Auth 3・DB 4（分析ONで5）。ツール説明・サーバーinstructions・顧客Skillを「占いは計算ツールを直接呼ぶ（tier・残回数・FEATURE_NOT_INCLUDED等は結果に含まれる）。状態確認はユーザーが求めたときだけ」に変更し、**直接呼べば HTTP 1・Auth 1・DB 1**。ローカル実測p50の単純和では 約410ms → 約136ms（分析ON）。ただしホストが説明に従うかは実ホスト（ChatGPT/Claude/Codex）で未検証（BLOCKED）。認可はサーバー側のままで、ホストの判断に依存しない。

## 4. migration 08（forward-fix）

`20261015062212_fj_v02_08_single_roundtrip_mcp.sql`（CLI生成、manifest登録）:

- `fj_record_calculation`（同じ引数で置換）: 既存readingの照合をtier判定より前に行う。tarotは日付に依存しないため、同一drawId・同一入力の再試行は送られた日付に関係なく元の行をreplay（元の日付は書き換えない）。numerologyは従来どおり日付不一致を `IDEMPOTENCY_CONFLICT`。
  - 挙動の変更点は1つ: **Trial終了後の同一再試行**は、従来 `FEATURE_NOT_INCLUDED` だったが、配布済みの結果をreplayする（利用回数を消費しない・新しい抽選はしない）。停止アカウントは従来どおり先に拒否、Freeの新規tarotは従来どおり拒否。**この仕様変更はオーナーが2026-10-15に承認（PR #1）。**
- `fj_access_snapshot(uuid)`: STABLE / SECURITY INVOKER / `search_path=''` / service_role のみEXECUTE。返すのは従来2クエリで読んでいた列（trial_ends_at, suspended_at, status, current_period_end, verified_at）だけで、課金ID・金額は返さない。形が想定外ならTS側で失敗扱い（fail closed）。
- **適用順**: 08 → アプリ。08適用後の旧アプリはそのまま動く。逆順は不可（UPGRADE.md）。

## 5. 実測結果（n=100、ローカル）

DB on path = サーバー側 `outbound_db_calls`（応答前に完了したDB呼出し）。Kong = 応答後も含む総数。

### 分析OFF（Staging初期値）

| tool | Auth | DB (Kong) | DB on path | client p50 ms | client p95 ms | server db_ms p50 | server db_ms p95 |
|---|---|---|---|---|---|---|---|
| get_account_profile | 1→1 | 0→0 | 0→0 | 113.2→111.8 | 215.9→241.8 | 0→0 | 0→0 |
| get_access_status | 1→1 | **2→1** | 2→1 | 130.0→136.6 | 222.9→197.5 | **13.5→8.7（−36%）** | **29.2→17.5（−40%）** |
| get_journal_schema | 1→1 | 0→0 | 0→0 | 112.4→121.3 | 226.8→200.3 | 0→0 | 0→0 |
| calculate_numerology | 1→1 | 1→1 | 1→1 | 127.9→133.2 | 199.0→210.0 | 11.5→11.4 | 19.3→26.6 |
| draw_tarot | 1→1 | **2→1** | 2→1 | 138.7→131.7 | 203.7→272.8 | **17.0→11.5（−33%）** | **31.2→25.1（−20%）** |
| draw_tarot（replay） | 1→1 | **2→1** | 2→1 | 146.9→132.4 | 233.9→220.6 | **17.8→10.4（−42%）** | **26.0→20.2（−22%）** |
| submit_reading_feedback | 1→1 | 0→0 | 0→0 | 114.2→126.2 | 287.0→191.4 | 0→0 | 0→0 |
| report_journal_action | 1→1 | 0→0 | 0→0 | 116.3→116.3 | 202.8→187.1 | 0→0 | 0→0 |

### 分析ON（同意済みユーザー）

| tool | Auth | DB (Kong) | DB on path | client p50 ms | client p95 ms | server db_ms p50 | server db_ms p95 |
|---|---|---|---|---|---|---|---|
| get_account_profile | 1→1 | 1→1 | **1→0** | 140.4→127.6 | 256.5→223.0 | **11.2→0** | **21.7→0** |
| get_access_status | 1→1 | **2→1** | 2→1 | 129.9→126.2 | 226.1→176.0 | **14.3→7.6（−47%）** | **26.9→15.7（−42%）** |
| get_journal_schema | 1→1 | 0→0 | 0→0 | 116.0→118.2 | 201.2→178.9 | 0→0 | 0→0 |
| calculate_numerology | 1→1 | 1→1 | 1→1 | 128.9→135.0 | 236.0→194.4 | 12.1→11.5 | 25.6→20.0 |
| draw_tarot | 1→1 | **2→1** | 2→1 | 140.3→136.0 | 243.9→225.6 | **17.8→11.9（−33%）** | **33.3→25.3（−24%）** |
| draw_tarot（replay） | 1→1 | **2→1** | 2→1 | 135.7→129.8 | 220.8→193.9 | **16.0→10.6（−34%）** | **31.6→21.9（−31%）** |
| submit_reading_feedback | 1→1 | 1→1 | 1→1 | 124.6→124.6 | 190.7→201.7 | 9.8→10.1 | 18.0→19.8 |
| report_journal_action | 1→1 | 1→1 | 1→1 | 138.1→128.9 | 203.6→200.4 | 10.5→11.0 | 21.2→21.7 |

成功率: 全シナリオで Before/After 同一（分析OFFの feedback/report は仕様どおり `OPTIONAL_ANALYTICS_DISABLED`、それ以外 100%）。Auth時間（p50）は Before 96–114ms、After 98–113ms で変化なし（=Authは削っていない）。

**評価**: 通信回数の削減（tarot・access 2→1、profile計測の応答経路外し、期限切れ401のAuth 1→0）はKongで確認済み。応答経路上のDB時間は p50で約33–47%減。エンドツーエンドp50/p95の差（−10%〜+12%、一部p95 +34%）はローカルGoTrueの揺らぎの範囲で、**有意な改善とも悪化とも言えない**。本番ではVercel↔Supabase間のRTT（同一リージョンで数ms〜、別リージョンで数十ms）×削減往復数が効くが、未測定。

## 6. 計測（Phase E）

- `src/lib/perf.ts`: AsyncLocalStorageでリクエスト単位に Auth/PostgREST の回数と時間を集計（Supabaseクライアントの `global.fetch` を計測fetchに差し替え。リクエスト外では素通し）。
- `MCP_TIMING_LOG=true` のときだけ1ツール呼出し1行 `FJ_MCP_TIMING {tool, ok, error_code, total_ms, auth_ms, db_ms, calculation_ms, outbound_auth_calls, outbound_db_calls}`。入力・ユーザーID・トークン・結果は出さない。エラーコードは `^[A-Z_]{1,64}$` 以外を `UNKNOWN_ERROR` に丸める。DB書込みなし、新サービスなし。既定OFF（ログ肥大防止）。
- 成功率はこの行の `ok` を集計する。

## 7. 残存リスク・未検証

- 実Vercel/実Supabase（Staging）での往復時間・コールドスタート: 未測定（BLOCKED: Staging未作成）。
- ChatGPT/Claude/Codex実ホストがツール説明に従って事前呼出しを省くか: 未検証（BLOCKED）。
- `after()` はVercel上で `waitUntil` 相当として動く前提（Next.js 15.5のNode runtime）。ローカル `next start` ではE2Eでイベント記録を確認。Vercel上は未検証。関数がafter処理前に打ち切られた場合は任意の `mcp_connected` イベントが欠測するだけで、利用者データ・課金・quotaには影響しない。
- 署名済みかつ期限切れのOAuthトークンのE2E: ローカルstackがES256で秘密鍵を取り出せないためE2Eでは改ざんトークンのみ確認。期限切れはunit（事前チェック）＋Kong 0呼出しの実測で確認。
