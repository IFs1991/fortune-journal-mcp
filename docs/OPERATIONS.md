# Operations runbook

これは手順書であり、実行済みの証拠ではない（証拠は [verification/RESULTS.md](../verification/RESULTS.md)）。承認の要否は [AGENTS.md](../AGENTS.md) §2。**★ = 対象IDを示してオーナーの明示承認を得てから**。

## 1. ローカル検証（承認不要）

前提: Node 22.16+（Vercelは24.x、CIは両方）、npm 10、Docker、Supabase CLI 2.120.0、psql。

```bash
npm ci
npm run release:check            # format・static・unit・typecheck・build・使い捨てPG（全スイート/並列/dump-restore）・schema差分・audit
supabase start --network-id fj_local_net   # 専用 project_id fortune-journal-local、554xx。初回: docker network create --subnet 10.253.17.0/24 fj_local_net
supabase db reset --local --network-id fj_local_net   # migrationを変えたとき
npm run test:db:supabase         # 実Supabaseイメージで全SQLスイート
supabase db advisors --local --type all --level warn --fail-on warn
```

E2E（GoTrue OAuth 2.1 + PostgREST + このapp）: 使い捨て秘密を生成してリポジトリ外のファイルに置き、`APP_ORIGIN=http://localhost:3000` で `npm run build && npx next start -p 3000`。

```bash
PRODUCT_ANALYTICS_ENABLED=false OPERATIONS_ENABLED=false node --experimental-strip-types scripts/e2e-local.mjs   # 19 checks
PRODUCT_ANALYTICS_ENABLED=true  OPERATIONS_ENABLED=true  node --experimental-strip-types scripts/e2e-local.mjs   # 20 checks（appも同じflagで起動）
node scripts/bench-mcp-local.mjs --samples 100 --server-log <app-stdout> --out <file>   # appは MCP_TIMING_LOG=true
node scripts/probe-resource-audience.mjs   # tokenのaudがresourceに束縛されるか
```

スクリプトはloopback以外を拒否し、token・鍵を表示しない。テストユーザーはAdmin APIで作り最後に削除する。`.env.local` をプロジェクト直下に置かない（`check:static` が拒否）。

## 2. 現在のリモート状態（read-only確認 2026-10-16）

- Vercel project `fortune-journal-mcp`（team「Toshu's projects」、Pro）がGitHub連携済み。**Production branch = `main`: mainへのmergeはProduction deploy。** env 0件、Node 24.x、`iad1`、Deployment Protection = All Deployments（2026-10-16 オーナー承認で変更）。詳細と修正計画: [verification/vercel_audit_2026-10-16.md](../verification/vercel_audit_2026-10-16.md)。
- Fortune Journal用のSupabase projectは**存在しない**（同じアカウントの3 projectは他サービス。触れない）。
- ブランチのpushでPreview deployが自動作成される。

## 3. Staging構築（すべて★）

### 3.1 Supabase（新規・専用project。共有しない: audienceの前提、[SECURITY.md](SECURITY.md)）

| 項目 | 設定 |
|---|---|
| Project | 新規 `fortune-journal-staging`。名前で既存projectを推測選択せず ref を目視確認 |
| Region | Vercel Functionsに近い場所（`iad1` なら `us-east-1`） |
| Auth → URL | Site URL = `APP_ORIGIN`、Redirect URLs = `APP_ORIGIN/auth/callback` の完全一致のみ |
| Auth → Providers | Googleのみ。Email/Phone/Anonymous無効。Sign-up有効（Google初回ログインに必要） |
| Google Cloud | Staging専用OAuth client。redirect `https://<ref>.supabase.co/auth/v1/callback`。scope openid/email/profileのみ |
| Auth → OAuth Server | 有効、Authorization path `/oauth/consent`。DCRはChatGPT/Claude接続に必要なら有効（未登録clientは同意画面で unverified） |
| JWT Signing Keys | 非対称（ES256推奨）。`getUser()` 検証なので方式に依存しない |
| Data API | Exposed schema = `public` のみ（どの表にも権限はない）。GraphQL未使用なら無効化を検討 |

`supabase/config.toml` はローカル専用。**Stagingへ `supabase config push` しない。**

### 3.2 DB適用

```bash
supabase link --project-ref <staging-ref>     # 目視確認。既存projectのrefを絶対に指定しない
supabase migration list --linked              # 期待: remoteは空
supabase db push --linked --dry-run           # 期待: 20261016022037_baseline.sql の1本だけ
supabase db push --linked                     # ★
supabase migration list --linked              # local/remote一致
psql "$STAGING_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/catalog.sql   # read-only・rollback
supabase db advisors --linked --type all --level warn --fail-on warn
```

push後、同じPRで `supabase/applied-migrations.json` に `"20261016022037_baseline.sql": "<sha256>"` を登録する（以後このファイルは不変）。Staging DBには `catalog.sql` 以外の書込み系スイートを流さない。

### 3.3 Vercel

既存 `fortune-journal-mcp` のPreview環境を使うか、新規 `fortune-journal-staging` を作るかはオーナーが決める（監査ファイルの修正計画）。Node 22.x/24.x はCIで両方ビルド済み。cronはProduction deploymentでのみ起動するため、Previewでは手動で `GET /api/cron/maintenance`（Bearer）を叩く。Deployment Protection下では外部ホスト（ChatGPT/Claude/Google）から到達できないので、外部E2Eは保護を外したStaging domainかテスト時だけのProtection Bypass（★）。`/api/mcp`・`/api/ops`・`/oauth/*` にFirewall rate limitを推奨。

### 3.4 環境変数（`.env.example` が一覧の正本）

| 変数 | 値 | 注意 |
|---|---|---|
| `APP_ORIGIN` | 実HTTPS origin | Site URL・同意URL・PRMの `resource` と一致 |
| `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Staging project | build時に埋め込み。変えたら再build |
| `SUPABASE_SECRET_KEY` | Staging secret key | serverのみ、Sensitive |
| `REQUEST_HMAC_KEY` `TAROT_HMAC_KEY` `OPS_HMAC_KEY` `ATTRIBUTION_HMAC_KEY` `CRON_SECRET` | 各々独立に `node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"` | 共用禁止。TAROT/REQUESTの変更は再現性と重複排除を壊す |
| `TAROT_KEY_VERSION` | `v1` | 鍵ローテーション時に上げる |
| `PRODUCT_ANALYTICS_ENABLED` `OPERATIONS_ENABLED` `THREADS_INSIGHTS_ENABLED` `THREADS_PUBLISH_ENABLED` | すべて `false` | 初回Stagingは全OFF |
| `THREADS_ACCOUNT_ID` `THREADS_ACCESS_TOKEN` `THREADS_API_VERSION` | 空 | Meta権限・API版の確認まで BLOCKED |
| `MCP_CLIENT_NAMES_JSON` | `{}` | 確認したclient_idだけ `{"<id>":"chatgpt"}`（同意画面のverified表示と接続イベント分類。流入元ではない） |
| `MCP_TIMING_LOG` | `false` | 計測時だけ `true`（`FJ_MCP_TIMING` 1行/呼出し、入力・ID・tokenなし） |

### 3.5 Staging E2E

1. `/api/health` 200、`/api/billing/webhook` 501、`/api/ops` 503（OPS無効）。
2. 無トークン `POST /api/mcp` → 401 + `resource_metadata=APP_ORIGIN/.well-known/oauth-protected-resource`。PRMの `authorization_servers` = `https://<ref>.supabase.co/auth/v1`。
3. AS metadata（`/.well-known/oauth-authorization-server/auth/v1` と `/auth/v1/.well-known/oauth-authorization-server`）。
4. 実Googleログイン（Email UIなし、Drive/Sheets scopeなし）。
5. MCP Inspector / Claude / ChatGPT で接続 → 同意画面 → tools/list 7件 → `calculate_numerology` を同じrequestIdで2回 → replayed。
6. Deny → `access_denied`。Connected AI apps から Revoke → 直後に401。
7. 初回計算前 `get_access_status` = free、初回計算後 trial。
8. アカウント削除 → 既存tokenが401。
9. Google Sheets（顧客側コネクタ、手動）: 作成・追記・読戻し・record_id重複回避・式文字列の無害化・未接続/拒否時に「保存した」と言わない。
10. cron（Bearer）→ 200 と `FJ_MAINTENANCE_OK`。
11. `node scripts/probe-resource-audience.mjs` 相当の確認（hosted Supabaseのaud挙動）。

## 4. デプロイ（★）

mainへのmerge = Production deploy。Productionは別gate（[DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md)）。デプロイ前に target ID・commit・env・DB状態・backupを確認する。DB変更を含むときは **DBを先に適用**してからアプリをdeployする。

## 5. 監視と即時停止

監視するログコード: `FJ_MAINTENANCE_FAILED` / `FJ_MAINTENANCE_PARTIAL_FAILURE` / `FJ_CRON_NOT_CONFIGURED` / `FJ_OPS_FAILED` / `FJ_ATTRIBUTION_NOT_RECORDED` / `FJ_CONNECTION_TELEMETRY_UNAVAILABLE`。通知先（log drain / alert）は未接続 = BLOCKED。

即時停止（flagsをfalse、Preview無効化、必要ならInstant Rollback ★）: 他ユーザーのデータが見える / anonでデータが読める / `/api/mcp` の5xx継続・無トークン200 / advisorsにsecurityのWARN・ERROR / `billing_events`・`subscriptions` への想定外の書込み・Premium付与 / 同意なしの `funnel_events`・topic。

## 6. バックアップと復旧

- 適用前: `supabase db dump --linked -f backups/<env>-schema.sql` と `--data-only`（`backups/` はgitignore）。FreeプランにPITRはない。
- 不具合は新しいmigrationで前進修正（down migrationはない）。適用済みファイルは編集しない。
- 復元が必要な場合は、承認後に新規projectへ復元して切り替える（既存DBへの上書き復元はしない）。`pg_dump`/`pg_restore` で権限契約と行数が保たれることは `test-db.sh` で確認済み（使い捨てPG）。hosted Supabaseでの復元は NOT RUN。
- アプリはVercelの以前のdeploymentへInstant Rollbackできるが、DBが前進していれば古いアプリと組み合わせない。

## 7. Threads運営（運営者自身の1アカウントのみ）

- Meta公式文書で対象API版と `threads_basic`・`threads_manage_insights`・公開権限を確認し実機で検証する（未実施 = BLOCKED）。tokenはenvだけ。自動token refreshは未実装。
- コマンドは `node --env-file=<repo外のenv> --experimental-strip-types scripts/ops.mjs <command.json>`（例は `ops/examples/`）。一覧と入力検証は `src/ops/commands.ts`。
- 流れ: `draft_post`（requestId = postId）→ `approve_post`（返された bodySha256 だけを承認。本文が変わったら再承認）→ `publish_post`（`THREADS_PUBLISH_ENABLED`・承認・予定時刻の到達を確認し1回だけclaim）。
- **結果不明（timeout・応答なし・確定書込み失敗・lease切れ）は `publish_unknown`。自動再投稿しない。** 投稿一覧と既知のcontainerを照合し、公開済みなら承認済み保守手順で `fj_finish_publish` に外部IDを記録。未公開が確認できても旧post/runは残し、明示承認付きで新しいpostとして作り直す。
- `import_posts` は1ページずつ（nextCursorを明示的に続ける）。`collect_*` の過去値を再現・捏造しない。時刻を逃した観測は欠測のまま。
- cron: 日次purge、24/72/168h到達の投稿を最大3件、日次account snapshot。投稿探索は直近170h・250件まで（それを超える運用は再設計）。
- 週次: read-only `report` → 母数・欠測・成熟を確認 → 仮説は最大2つを `ops/experiments/` に → 承認範囲のdraft。外部で行った分析・下書きは `record_external_run` で開始/終了/既知の費用だけ申告（内容は送らない。プロバイダー実測と区別される）。
