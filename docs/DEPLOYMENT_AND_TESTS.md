# Setup / test / Staging deployment runbook (v0.2.1)

この文書は**手順書**であり、デプロイ済みの証拠ではない。実行結果は [verification/RESULTS.md](../verification/RESULTS.md)。
Staging/Productionへのリモート書き込み（Supabase project作成・`db push`・`config push`・Vercel project作成・env設定・deploy・Google/Meta設定）は、**対象ID・変更内容・リスク・ロールバックを提示してオーナーの明示承認を得てから**行う。既存Tiramisu WorksのSupabase/Vercel/GitHub/鍵/DBは対象外。

CLI flagは Supabase CLI 2.120.0 の `--help` で 2026-10-15 に確認済み。CLI更新後は再確認する。

## 1. ローカル検証（承認不要）

前提: Node 22.16+ / npm 10、Docker、Supabase CLI 2.120.0、psql。

```bash
npm ci
npm run release:check        # db:check-prepared + test + check:static + typecheck + build + test:db + npm audit
supabase start               # 専用project_id fortune-journal-local、554xxポート。他projectのstackに触れない
npm run test:db:supabase     # 実Supabase Postgresイメージで全SQLスイート（loopbackのみ許可）
```

Docker既定のアドレスプールが枯渇している場合は、既存networkを削除せず専用networkを作る:
`docker network create --subnet 10.253.17.0/24 fj_local_net` → `supabase start --network-id fj_local_net`（`db reset`にも同じflag）。

E2E（ローカルstackのGoTrue OAuth 2.1 + PostgREST + このapp）:

```bash
# 使い捨て秘密を生成して env に入れ（ファイルはリポジトリ外）、APP_ORIGIN=http://localhost:3000 で build/start
npm run build && npx next start -p 3000
PRODUCT_ANALYTICS_ENABLED=false OPERATIONS_ENABLED=false node scripts/e2e-local.mjs   # 15 checks
PRODUCT_ANALYTICS_ENABLED=true  OPERATIONS_ENABLED=true  node scripts/e2e-local.mjs   # 16 checks（appも同flagで起動）
```

E2Eスクリプトはloopback以外を拒否し、トークン/鍵を表示しない。テストユーザーはAdmin APIで作成し、終了時に削除する。
`.env.local` はプロジェクト直下に置かない（`check:static` が拒否する）。

## 2. Staging構成（作成はすべて要承認）

### 2.1 Supabase（新規・専用project）

2026-10-15時点のread-only確認では Fortune Journal用projectは**存在しない**。同一organizationのFreeプランはactive 2件の上限に達している可能性があるため、作成先org/プランをオーナーが決める。

| 項目 | 設定 |
|---|---|
| Project | 新規 `fortune-journal-staging`（名前で既存projectを推測選択しない。ref を目視確認） |
| Region | Vercel Functionsのregionに近い場所（例: Vercel `iad1` なら `us-east-1`） |
| Auth → URL Configuration | Site URL = `APP_ORIGIN`。Redirect URLs = `APP_ORIGIN/auth/callback` の完全一致のみ（ワイルドカード不可） |
| Auth → Providers | **Googleのみ有効**。Email / Phone / Anonymous は無効。Sign-upは有効（Google初回ログインに必要） |
| Google Cloud | Staging専用のOAuth client。Authorized redirect URI = `https://<ref>.supabase.co/auth/v1/callback`。scopeは openid/email/profile のみ。**Drive/Sheets scopeを追加しない** |
| Auth → OAuth Server | 有効。Authorization path = `/oauth/consent`。Dynamic Client Registration は ChatGPT/Claude 接続に必要なら有効（同意画面は未登録clientを「unverified」と表示） |
| Auth → JWT Signing Keys | 非対称鍵（ES256推奨）へ移行。`/api/mcp` は `auth.getUser` で検証するため鍵方式に依存しない |
| Data API | Exposed schema = `public` のみ。GraphQL未使用なら無効化を検討 |
| Backups | Freeは自動PITRなし。適用前に `db dump` を取得（下記） |

`supabase/config.toml` はローカル専用。**`supabase config push` をStagingに実行しない**（ローカルの `allow_dynamic_registration` やポートを誤って反映しうる）。Auth設定はDashboardで行う。

### 2.2 Vercel（新規・専用project）

read-only確認では Fortune Journal用Vercel projectは**存在しない**（既存の `uranai` 等を名前から流用しない。関連性はオーナーが判断）。

| 項目 | 設定 |
|---|---|
| Project | 新規 `fortune-journal-staging`、Framework = Next.js、Node.js = 22.x（CIと一致。24.xへ上げる場合は再検証） |
| Env (Preview/Staging) | 下表。秘密は Sensitive として Dashboard/`vercel env add` で入力。会話・ログ・Gitに貼らない |
| Cron | `vercel.json` は毎時 `15 * * * *`。**Hobbyは日次cronのみ**のため、Hobbyではデプロイ失敗する。Pro利用か日次化をオーナーが決定。cronは**Production deploymentでのみ**起動するため、Previewでは手動で `GET /api/cron/maintenance`（Bearer CRON_SECRET）を叩いて確認 |
| Deployment Protection | Vercel Authentication有効のPreviewには ChatGPT/Claude/Google からアクセスできない。外部MCP E2Eは保護を外したStaging用domain、またはProtection Bypass for Automation（テスト時のみ）で行う。保護解除は要承認 |
| Firewall | `/api/mcp`・`/api/ops`・`/oauth/*` へのrate limit（Vercel Firewall）を推奨。アプリ内にレート制限はない |

### 2.3 環境変数（`.env.example` と実参照を 2026-10-15 に突合、差分なし。`SUPABASE_CLI` はスクリプト用の任意上書きのみ）

| Variable | 値の出所 | 備考 |
|---|---|---|
| `APP_ORIGIN` | Stagingの実HTTPS origin | Supabase Site URL・同意URL・PRMの `resource` と一致必須 |
| `NEXT_PUBLIC_SUPABASE_URL` | Staging project URL | **build時に埋め込まれる**。変更したら再build |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Staging publishable key | 同上 |
| `SUPABASE_SECRET_KEY` | Staging secret key | serverのみ。Sensitive |
| `REQUEST_HMAC_KEY` `TAROT_HMAC_KEY` `OPS_HMAC_KEY` `ATTRIBUTION_HMAC_KEY` `CRON_SECRET` | それぞれ独立に `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"` | 共用禁止。TAROT/REQUEST鍵の変更は再現性と90日dedupを壊す |
| `TAROT_KEY_VERSION` | `v1` | 鍵ローテーション時に上げる |
| `PRODUCT_ANALYTICS_ENABLED` `OPERATIONS_ENABLED` `THREADS_INSIGHTS_ENABLED` `THREADS_PUBLISH_ENABLED` | すべて `false` | 初回Stagingは全OFF |
| `THREADS_ACCOUNT_ID` `THREADS_ACCESS_TOKEN` `THREADS_API_VERSION` | 空 | Meta権限/API版確認まで BLOCKED |
| `MCP_CLIENT_NAMES_JSON` | `{}` | 実際に確認したOAuth client_idだけを `{"<id>":"chatgpt"}` 形式で追加（同意画面の verified 表示と接続イベント分類に使う。流入元ではない） |

## 3. Staging DB 適用順（`db push` は要承認）

```bash
supabase link --project-ref <staging-ref>             # refを目視確認。Tiramisu等の既存refを絶対に指定しない
supabase migration list --linked                        # 期待: remote履歴が空（新規project）
mkdir -p backups                                        # backups/ は .gitignore 対象
supabase db dump --linked -f backups/staging-pre-v021-schema.sql
supabase db dump --linked --data-only -f backups/staging-pre-v021-data.sql
supabase db push --linked --dry-run                     # 期待: 8本（initial + v02 01..05 + 06 + 07）。それ以外が出たら停止
supabase db push --linked                               # ★承認後のみ
supabase migration list --linked                        # local/remote 8本一致を確認
psql "$STAGING_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_security.sql   # read-onlyのcatalog検査のみ
supabase db advisors --linked --type all --level warn --fail-on warn
```

Staging DBには書き込み系SQLテスト（`v02_*.sql`）を流さない。書き込みを伴う検証はローカルstackと下記のアプリE2Eで行う。

### ロールバック方針（down migrationなし）

- **戻せない点**: 05 は旧 `consume_usage` を service_role からも撤回する（v0.1アプリは動作しない）。06 は旧4引数 `fj_set_privacy` をDROPし5引数版に置換（第5引数はDEFAULT NULLなので4引数呼び出しは動くが、登録cohortは記録されない）。01 はTrial列のNOT NULL/DEFAULTを外す。
- 不具合は**新しい forward-fix migration**（`supabase migration new` → `supabase/migration-manifest.json` の `forwardFixes` にhash登録 → `npm run db:check-prepared`）で直す。適用済みファイルは編集しない。
- 復元が必要な場合のみ、承認後に `backups/` のdumpから新規projectへ復元して切替える（既存DBへの上書き復元はしない）。
- アプリ側はVercelの以前のdeploymentへInstant Rollback可能。ただしDBは前進済みのため、v0.2.1未満のアプリへは戻さない。

## 4. Vercel Staging デプロイ（要承認）

```bash
vercel link                                   # 新規 fortune-journal-staging を選択（既存projectを選ばない）
vercel env ls                                 # read-only: 2.3 の変数が揃っていることを確認
vercel deploy                                 # Preview。★承認後のみ（--prod は使わない）
```

## 5. Staging E2E チェックリスト

自動（ローカルと同じ観点をStaging URLで手動/半自動確認）:

1. `GET /api/health` 200、`POST /api/billing/webhook` 501、`/api/ops` 503（OPERATIONS_ENABLED=false）。
2. `POST /api/mcp`（無トークン）→ 401、`WWW-Authenticate` の `resource_metadata` が `APP_ORIGIN/.well-known/oauth-protected-resource`。PRMの `authorization_servers` = `https://<ref>.supabase.co/auth/v1`。
3. Supabase AS metadata: `https://<ref>.supabase.co/.well-known/oauth-authorization-server/auth/v1`（RFC 8414 path挿入形）と `/auth/v1/.well-known/oauth-authorization-server` の両方を確認。ローカルstackでは後者のみ応答（Kong構成差）。
4. 実Googleアカウントでログイン（Email/Password UIがないこと、Drive/Sheets scopeを要求しないこと）。
5. MCP Inspector または Claude/ChatGPT のカスタムコネクタで `https://<staging>/api/mcp` を追加 → 同意画面（client名・unverified表示・callback host）→ Allow → tools/list 7件 → `calculate_numerology` 2回同一requestIdで replayed。
6. Deny → クライアントに `access_denied`。/login の Connected AI apps から Revoke → 直後のMCP呼出しが401。
7. Free/Trial: 初回計算前 `get_access_status`=free、初回計算後 trial（同意だけでは開始しない）。
8. アカウント削除（DELETE_MY_ACCOUNT）→ 既存MCPトークンが401。
9. **Google Sheets（手動・顧客側コネクタ）**: ワークブック作成 → Fortune Log 追記 → 読み戻し → 同一record_idの重複追記を避ける → `=HYPERLINK(...)` 等の式文字列がRAW/アポストロフィで無害化 → Sheetsコネクタ未接続/拒否時に「保存した」と言わない → 他人のSheetへの書込み不可。自社MCPはGoogleに一切アクセスしないため、ここは顧客側AIの挙動確認であり自動化していない。
10. `GET /api/cron/maintenance`（Bearer CRON_SECRET）→ 200 と `FJ_MAINTENANCE_OK` ログ。

## 6. 観測と停止条件

監視するログコード: `FJ_MAINTENANCE_FAILED` / `FJ_MAINTENANCE_PARTIAL_FAILURE` / `FJ_CRON_NOT_CONFIGURED` / `FJ_OPS_FAILED` / `FJ_ATTRIBUTION_NOT_RECORDED` / `FJ_CONNECTION_TELEMETRY_UNAVAILABLE`。通知先（Vercel log drain / alert）は未接続 = BLOCKED。

即時停止（Previewを無効化・flagsをfalse・必要ならInstant Rollback）:
- 他ユーザーのデータが見える、またはanonでデータが読める
- `/api/mcp` の5xxが継続、または無トークンで200
- `supabase db advisors` に WARN/ERROR（security）
- `billing_events`/`subscriptions` への想定外の書込み、Premiumの付与
- 同意なしの `funnel_events`/topic 記録

## 7. CI

`.github/workflows/ci.yml`（PR / main push / 手動）: `build`（npm ci・test・static・db:check-prepared・typecheck・build・audit）、`database`（使い捨てPostgres 17 digest固定）、`supabase-local`（Supabase CLI 2.120.0 で実stack + SQLスイート + E2E 2モード）。秘密値は不要、deployしない。**GitHub remote未設定のため未実行**。初回push後に結果を確認する。

## 8. Release

`npm run release:check` は未準備migration・manifest未登録migration・型/ビルド失敗・重大脆弱性を拒否する。外部E2E結果・target project ID・commit・env・backup・migration状態を確認してから承認済み手順で deploy。Productionは別gate（DoD参照）。
