# Vercel project audit — 2026-10-16 02:30–02:45 JST（read-only）

対象: Vercel project `fortune-journal-mcp`（`prj_1ruiiZXngm2W1L4szl9oUC6L1X4R`、team「Toshu's projects」`team_YfzYoYb6zP21dvLKOhrxZYen`、plan **Pro**）。
GitHub `IFs1991/fortune-journal-mcp` にGit連携済み。PR #1 のマージ（f15bb55、オーナー承認済み）で Production に自動デプロイされた。

方法: Vercel CLI 54.18.6（`ifs1991` でログイン済み、このディレクトリは `.vercel/project.json` で同projectにlink済み）の read-only コマンドのみ —
`vercel project inspect` / `vercel env ls` / `vercel ls` / `vercel inspect` / `vercel logs` / `vercel api`（GET: `/v9/projects/<id>`, `/v2/teams/<id>`, `/v13/deployments/<id>`）、および公開URLへの無認証 `curl`。
Supabase は `supabase projects list`（read-only）のみ。**env・設定・deploy・Supabaseには一切書き込んでいない。** 環境変数の値は取得・表示していない（そもそも0件）。

副作用の申告: `vercel project inspect` 実行時に Vercel CLI が自身の Claude plugin を自動更新した（2026-10-15 の監査と同じCLI挙動。project/deploymentの変更ではない）。

## 設定（実測）

| 項目 | 実測値 | runbook（DEPLOYMENT_AND_TESTS.md §2）との差 |
|---|---|---|
| Project | `fortune-journal-mcp`（2026-10-15 08:32 JST作成） | runbookは新規 `fortune-journal-staging` を想定。このprojectは **Production**（main）を配信している |
| Production branch | `main`（Git連携、deploy hookなし、fork protection有効） | runbookは `vercel deploy`（Previewのみ、`--prod` なし）を想定。**mainへのマージ＝Production deploy** |
| Framework | Next.js（build/install/output は既定、Root `.`） | 一致 |
| Node.js | **24.x** | runbook/CI は 22.x（CI 22.16.0、ローカル 22.22.2）。`engines` は `>=22.16.0` なので24でもbuildは通るが未検証 |
| Function region | `iad1`、Fluid compute 有効 | Supabaseは `us-east-1` を推奨（§2.1どおり） |
| Deployment Protection | Vercel Authentication、scope **Standard Protection**（`all_except_custom_domains`）。Password/Trusted IPs なし、Protection Bypass for Automation 0件 | deployment URL・`-git-main-`・team aliasは保護（302→Vercelログイン）。**本番ドメイン `fortune-journal-mcp.vercel.app` は公開** |
| Cron | 有効。`/api/cron/maintenance` `15 * * * *`、現Production deploymentに登録 | Proのため毎時cronは許可されdeployも成功（Hobby制約は該当せず）。ただし未設定のため毎時503 |
| Skew protection | 12h | — |
| System env自動公開 | 有効 | — |

## 環境変数（名前のみ）

`vercel env ls` → **0件**（Production / Preview / Development すべて）。§2.3 の全変数が未設定:
`APP_ORIGIN`, `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `REQUEST_HMAC_KEY`, `TAROT_HMAC_KEY`, `OPS_HMAC_KEY`, `ATTRIBUTION_HMAC_KEY`, `CRON_SECRET`, `TAROT_KEY_VERSION`, `PRODUCT_ANALYTICS_ENABLED`, `OPERATIONS_ENABLED`, `THREADS_INSIGHTS_ENABLED`, `THREADS_PUBLISH_ENABLED`, `THREADS_ACCOUNT_ID`, `THREADS_ACCESS_TOKEN`, `THREADS_API_VERSION`, `MCP_CLIENT_NAMES_JSON`, `MCP_TIMING_LOG`。

`NEXT_PUBLIC_SUPABASE_URL` が未設定のため、**このprojectはどのSupabase projectにも接続していない**。`supabase projects list` は `seikotsuin-management` / `tiramisu-works-studio`（ACTIVE）/ `exbition-meeting-manager`（INACTIVE）のみで、Fortune Journal用Supabase projectは依然として存在しない（2026-10-15から変化なし）。

## Deployments

| deployment | target | source / commit | 状態 |
|---|---|---|---|
| `dpl_DKrXVsjs81772erWtPHCn3UxhjYF`（2026-10-16 02:27 JST） | production（現alias） | git `main` f15bb55（PR #1 マージ） | READY、build 34s |
| `dpl_J8KFw5558pAGi72HbXdVmnqk19ay`（2026-10-15 15:40 JST） | production（旧） | git `perf/mcp-communication-optimization` f522827 | READY。PRブランチのcommitが production target でbuildされている（Git連携直後の初回deploymentと推定。現aliasではない） |
| 他2件 | preview | PR #1 ブランチ | READY |

GitHub Actions: main の f15bb55 push run 38777543463 は **success**（直前2回のmain失敗は解消）。

## 公開URLの挙動（無認証、2026-10-16 02:31 JST）

| request | status | runtime log（`vercel logs --environment production`） |
|---|---|---|
| `GET /api/health` | 200 `{"status":"up","version":"0.2.1","billing":"not_connected"}` | — |
| `POST /api/mcp`（tokenなし） | **500**（期待 401 + `WWW-Authenticate`） | `Error: APP_ORIGIN must be an HTTPS origin, or localhost for development`（`appOrigin()` が `withMcpAuth` の `resourceUrl` 構築時にthrow） |
| `GET /api/mcp` | 500 | 同上 |
| `GET /.well-known/oauth-protected-resource` | 500 | `Supabase public environment is not configured` |
| `GET /login` | 500 | middlewareの `publicConfig()` が同エラー |
| `GET /` | 307 | — |
| `GET /api/ops`, `GET /api/billing/webhook` | 405 | — |
| `GET /api/cron/maintenance`（無認証、Vercel cron含む） | 503 | `{"code":"FJ_CRON_NOT_CONFIGURED"}`（毎時 :15 に記録） |
| deployment URL / git-main / team alias の `/api/health` | 302（Vercelログインへ） | Standard Protection |

判断: すべて fail-closed（DB未接続、秘密値なし、データ露出なし）。ただし runbook §6 の停止条件「`/api/mcp` の5xxが継続」に該当し、RFC 9728 discovery（401 + `resource_metadata`）も成立しないため、MCPクライアントからは「壊れたサーバー」に見える。

## 修正計画（提案のみ・未実施。各手順は対象ID・変更・リスク・ロールバックを示してオーナーの個別承認後）

1. **【実施済み 2026-10-16 10:35 JST、下記「変更記録」】今すぐ（設定まで）Productionを閉じる** — Deployment Protection の scope を Standard → **All Deployments**（Vercel Authentication、全プランで追加費用なし）。本番ドメインも302になり、外部からの500露出が止まる。ロールバックは scope を戻すだけ。代替: Vercel の project pause（全URLが停止しcronも止まる）。Password Protection は Pro で $20/月/project のため不要。cron が保護下でどう扱われるかは切替後に `vercel logs` で確認する（現状どのみち503）。
2. **mainマージ＝Production deployを止めるか決める** — 選択肢: (a) Production branch を未使用ブランチ（例 `release`）に変更し、mainはPreviewにする、(b) Ignored Build Step で Production build を一時停止、(c) 現状維持（1の保護で十分とする）。推奨は (a)：P1判定までProductionに出さないというDoDのgateと一致する。
3. **トポロジーを決める** — 推奨: `fortune-journal-mcp` を将来のProduction専用とし、runbookどおり Staging は別Vercel project `fortune-journal-staging` + 別Supabase project で作る（鍵・DB・cronを環境ごとに分離）。代替: このprojectの Preview 環境を Staging とし、Preview専用env + 別Supabaseを使う（cronはProductionでしか走らないため手動確認が必要、§2.2）。
4. **Node.js を 22.x に固定**（CIと一致）— または CI に 24.x を追加して検証してから24を維持。どちらも設定変更なので要承認。
5. **Supabase を先に用意し、migration 08 まで適用してからenvを入れる** — 対象Supabase project作成（承認）→ Auth設定（§2.1）→ `db dump` → `db push --dry-run` で **9本（initial + 01..08）** を確認 → 承認 → `db push` → `migration list` 一致 → advisors。f15bb55 のアプリは 08 の `fj_record_calculation`（tarot replay）と `fj_access_snapshot` に依存するため、**08が適用されていないDBを `NEXT_PUBLIC_SUPABASE_URL` に指定してはいけない**。
6. **env を環境ごとに設定**（§2.3 の全19変数。秘密は Sensitive、HMAC/CRON鍵は環境ごとに独立生成、flagsは全false）。`APP_ORIGIN` は実際に配信するHTTPS origin（例 `https://fortune-journal-mcp.vercel.app` またはcustom domain）と一致させ、Supabase Site URL/Redirect URL も同じにする。`NEXT_PUBLIC_*` はbuild時埋め込みなので**env設定後に再deploy**が必要。
7. **再deploy後のsmoke**（保護下では `vercel curl` かProtection Bypass for Automationを一時使用）: `/api/health` 200、`POST /api/mcp` 無トークン 401 + `resource_metadata=APP_ORIGIN/.well-known/oauth-protected-resource`、PRM 200、`/login` 200、`/api/ops` 503、webhook 501、cron（Bearer CRON_SECRET）200。その後 §5 のStaging E2E。
8. 公開（scopeをStandardへ戻す）は P1 gate（実Google/実ホストOAuth E2E、Sheets手動E2E、法務文書、advisors）を満たしてから別承認。

## 変更記録（オーナー承認済みの書込み）

### 2026-10-16 10:35 JST（01:35:41Z）— Deployment Protection scope: Standard → All Deployments

- 承認: オーナーがチャットで「change fortune-journal-mcp Deployment Protection scope from Standard to All Deployments (Vercel Authentication). Nothing else.」と明示承認。
- 変更: `vercel api /v9/projects/prj_1ruiiZXngm2W1L4szl9oUC6L1X4R -X PATCH`、body `{"ssoProtection":{"deploymentType":"all"}}`（OpenAPIのenum `all` = All Deployments）。変更前 `all_except_custom_domains`。
- 他は変更していない（再GETで確認）: password/trusted IPs なし、env 0件、Node 24.x、Production branch `main`、cron定義そのまま、deployなし。
- 確認（無認証curl）: 本番ドメイン `GET /api/health`・`/api/mcp`・`/login`・PRM → **302**（`Location: https://vercel.com/sso-api?...`）、`POST /api/mcp` → **401**（Vercel SSOの応答、`_vercel_sso_nonce` cookie。アプリの `WWW-Authenticate` ではない）。外部への500露出は停止。
- 未確認: Vercel cron（毎時 :15）が保護下でどう扱われるか。次回実行後に `vercel logs --environment production` で確認する（未設定なのでどのみち503）。
- ロールバック: 同じPATCHで `{"ssoProtection":{"deploymentType":"all_except_custom_domains"}}`。
- 影響: env設定後のsmoke・MCP Inspector等の外部アクセスは、`vercel curl` か Protection Bypass for Automation（テスト時のみ、要承認）が必要。公開時は再度scope変更の承認が要る（計画 8）。
