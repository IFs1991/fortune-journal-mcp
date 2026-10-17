# Operations runbook

これは手順書であり、実行済みの証拠ではない（証拠は [verification/RESULTS.md](../verification/RESULTS.md)）。承認の要否は [AGENTS.md](../AGENTS.md) §2。**★ = 対象IDを示してオーナーの明示承認を得てから**。

## 1. ローカル検証（承認不要）

前提: Node 24（Vercelの実行環境）と 22.16+、npm 10、Docker、Supabase CLI 2.120.0、psql。**GitHub Actionsは使わない**（`.github/workflows/ci.yml` は参考定義で、受入れ基準にしない）。

単一コマンド（推奨）: すべてloopback、使い捨て秘密を毎回生成し表示しない、結果は `verification/local/summary.json` と各ログ。

```bash
npm run verify:local -- --npm-ci     # Node 24 で1回、Node 22 で1回。exit 0=全PASS / 1=FAIL / 2=BLOCKEDあり
```

内訳（個別に実行する場合）:

```bash
npm ci
npm run release:check            # format・static・unit・typecheck・build・使い捨てPG（全スイート/並列/dump-restore）・schema差分・audit
supabase start --network-id fj_local_net   # 専用 project_id fortune-journal-local、554xx。初回: docker network create --subnet 10.253.17.0/24 fj_local_net
supabase db reset --local --network-id fj_local_net   # migrationを変えたとき
npm run test:db:supabase         # 実Supabaseイメージで全SQLスイート
supabase db lint --local --fail-on warning
supabase db advisors --local --type all --level warn --fail-on warn
npm run test:ops:local           # 実DB + Threads偽装: 公開の success/failed/unknown、再投稿なし、resolve_publish、maintenance失敗
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
| **Auth → Hooks → Customize Access Token** | **有効**、type Postgres、`public.fj_access_token_hook`（§3.2のdb push後）。無効だとMCPは全401（fail closed）。OAuth clientのtokenが `aud = urn:fortune-journal:mcp` になることを§3.5で確認 |
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

適用順序: ①project作成とAuth設定（Hook以外）→ ②`db push`（baseline 1本。hook関数もここで作られる）→ ③catalog.sql・advisors → ④Auth Hookを有効化 → ⑤Vercel env設定とPreview deploy → ⑥§3.5。逆順（hookを先に有効化）は関数がなくtoken発行が失敗する。

push後、同じPRで `supabase/applied-migrations.json` に `"20261016022037_baseline.sql": "<sha256>"` を登録する（以後このファイルは不変）。Staging DBには `catalog.sql` 以外の書込み系スイートを流さない。

### 3.3 Vercel

既存 `fortune-journal-mcp` のPreview環境を使うか、新規 `fortune-journal-staging` を作るかはオーナーが決める（監査ファイルの修正計画）。Node 22.x/24.x はCIで両方ビルド済み。cronはProduction deploymentでのみ起動するため、Previewでは手動で `GET /api/cron/maintenance`（Bearer）を叩く。Deployment Protection下では外部ホスト（ChatGPT/Claude/Google）から到達できないので、外部E2Eは保護を外したStaging domainかテスト時だけのProtection Bypass（★）。

Firewall（★、未設定）: アプリ内の制限はインスタンス単位の最善努力なので、全体の上限をVercel Firewallのrate limit ruleで置く。初期値の目安: `/api/mcp` 送信元IPあたり 300 req/分、`/auth/callback`・`/api/oauth/*`・`/api/account/*` 60 req/分、`/api/ops` 30 req/分。超過時は429（deny）。ChatGPT/Claudeのegressは多数の利用者を束ねるため、`/api/mcp` は厳しくしすぎない（Staging実測後に調整）。

**Deployment Protection を外す条件**（Staging/Productionの公開用domainごとに★）: (1) §3.5の1–3・smokeがProtection Bypass経由でPASS、(2) envが `check-env` でPASS、(3) Auth HookとGoogleログインが有効、(4) advisorsにsecurity WARN/ERRORなし、(5) Firewall rate limitが有効、(6) 法務ページ（§8）が公開済み（無料βの条件）、(7) 即時停止手順（§5）の担当と通知先が決まっている。外した後もPreview（ブランチdeploy）は保護したまま。

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
| `WEB_SESSION_HMAC_KEY` | 独立に生成（上と同じ方法） | ブラウザセッションとGoogleログインcallbackの結び付け。変更すると全ブラウザが再ログイン（MCP接続は影響なし） |
| `MCP_CLIENT_NAMES_JSON` | `{}` | 確認したclient_idだけ `{"<id>":"chatgpt"}`（同意画面のverified表示と接続イベント分類。流入元ではない） |
| `MCP_ALLOWED_ORIGINS` | 空 | `/api/mcp` に `Origin` を付けて来るブラウザ型clientを許す場合だけ、完全一致のhttps originをカンマ区切り。ChatGPT/Claudeはサーバー側接続でOriginなし（Stagingで403が出たらログのOriginを確認して追加を判断） |
| `MCP_TIMING_LOG` | `false` | 計測時だけ `true`（`FJ_MCP_TIMING` 1行/呼出し、入力・ID・tokenなし） |

env確認（値を表示しない。pullしたファイルはリポジトリ外に置き、確認後に削除）:

```bash
vercel env pull --environment=preview /secure/tmp/fj-preview.env        # オーナー（read）
node scripts/check-env.mjs /secure/tmp/fj-preview.env --target preview   # Productionは --target production
```

### 3.5 Staging E2E（手動。ローカルE2Eで代替しない）

0. read-only smoke: `node scripts/smoke-remote.mjs https://<staging-domain> --supabase https://<ref>.supabase.co --mcp-json <staging用の.mcp.json>`（health・PRM・401 challenge・Origin 403・webhook 501・AS metadata・.mcp.json）。
1. `/api/health` 200（version）、`/api/billing/webhook` 501、`/api/ops` 503（OPS無効）。
2. 無トークン `POST /api/mcp` → 401 + `resource_metadata=APP_ORIGIN/.well-known/oauth-protected-resource`。PRMの `authorization_servers` = `https://<ref>.supabase.co/auth/v1`。`Origin: https://evil.example` → 403。
3. AS metadata（`/.well-known/oauth-authorization-server/auth/v1` と `/auth/v1/.well-known/oauth-authorization-server` のどちらが返るかを記録。ローカルCLIは後者だけ）。
4. 実Googleログイン（Email UIなし、Drive/Sheets scopeなし）。DevToolsで `__Host-fj-web-session` がHttpOnly・Secure・SameSite=Laxで付くこと。
5. MCP Inspector / Claude / ChatGPT で接続 → 同意画面 → tools/list 7件 → 発行tokenの `aud` が `urn:fortune-journal:mcp`（Inspectorで確認、tokenを記録しない）→ `calculate_numerology` を同じrequestIdで2回 → replayed。最初の数秘術・タロット鑑定がホスト上で表示されること。
6. Deny → `access_denied`。Connected AI apps から Revoke → 直後に401。refreshも失敗。
7. 初回計算前 `get_access_status` = free、初回計算後 trial（Trial終了・Free上限はローカルE2Eで検証済み。Stagingでは日付操作しない）。
8. 計測同意のON/OFF（`PRODUCT_ANALYTICS_ENABLED=false` の間は「disabled」表示）、エクスポートのダウンロード、アカウント削除 → 既存tokenが401。
9. Google Sheets（顧客側コネクタ、手動）: 作成・追記・読戻し・record_id重複回避・式文字列の無害化・未接続/拒否時に「保存した」と言わない。
10. cron（Bearer）→ 200 と `FJ_MAINTENANCE_OK`（失敗時は500と `FJ_MAINTENANCE_PARTIAL_FAILURE`）。
11. 結果を `verification/staging_<date>.md` に（command・時刻・commit・PASS/FAIL/BLOCKED、token・cookie・秘密なし）。

### 3.6 AI appへの接続（.mcp.json）

- 接続URLは `APP_ORIGIN/api/mcp`（Streamable HTTP）。`.mcp.json` は `{"type":"http","url":"https://<domain>/api/mcp"}`。リポジトリの値はdomain確定まで placeholder のまま（`check:static` が `type: "http"` を検査、`smoke-remote` がURLを検査）。domain確定時に同じPRで更新する。
- Claude（custom connector）・ChatGPT（developer mode / connector）ともURLだけを登録し、OAuthはDCR → 同意画面で行う。登録したclient_idを確認後 `MCP_CLIENT_NAMES_JSON` に追加（verified表示）。

## 4. デプロイ（★）

mainへのmerge = Production deploy。Productionは別gate（[DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md)）。デプロイ前に target ID・commit・env・DB状態・backupを確認する。DB変更を含むときは **DBを先に適用**してからアプリをdeployする。

手動デプロイ手順（GitHub Actionsを使わない）:

1. 対象commitで `npm run verify:local -- --npm-ci` をNode 24と22で実行し、`verification/local/summary.json` の `failed: 0` を確認（BLOCKEDは理由を記録）。
2. Staging: ブランチをpush → VercelのPreview deploymentが作られる（★push）。§3.4のenv確認 → §3.5。
3. Production（★、別承認）: Staging結果を添えてオーナーが承認 → Production用Supabaseに§3.1–3.2（backup → db push → Hook有効化）→ PRをmainへmerge（= Production deploy）→ smoke-remote → §3.5の1–8を本番で最小限（テスト用Googleアカウント、終了後に削除）。
4. ロールバック: アプリは Vercel Instant Rollback（★）で直前のdeploymentへ。DBは前進修正のみ（§6）。hookを無効化するとMCPは全401になる（緊急停止として使える、アプリのロールバックではない）。

## 5. 監視と即時停止

監視するログコード: `FJ_MAINTENANCE_FAILED` / `FJ_MAINTENANCE_PARTIAL_FAILURE`（cronは500、`permanentFailures>0` は人が対応）/ `FJ_CRON_NOT_CONFIGURED` / `FJ_OPS_FAILED` / `FJ_PUBLISH_UNKNOWN`（§7で照合）/ `FJ_PUBLISH_FAILED` / `FJ_ATTRIBUTION_NOT_RECORDED` / `FJ_CONNECTION_TELEMETRY_UNAVAILABLE`。HTTPでは `/api/mcp` の429・403・421の急増。課金: `fj_revenue_report` の `eventsNeedingReconciliation > 0`。通知先（log drain / alert）は未接続 = BLOCKED。

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
- 結果は3種類: `success`（公開・記録済み）/ `failed`（publish呼出し前の失敗 = 未公開確定。postは `approved` に戻り、オーナーの明示指示で `publish_post` をもう一度だけ実行できる、最大3回）/ `unknown`。応答の `recorded: false` はDBに結果が残っていない（lease切れで後から `unknown` になる）ことを意味するので、先にオーナーへ報告する。
- **結果不明（timeout・応答なし・不正な応答・成功の記録失敗・lease切れ）は `publish_unknown`。自動再投稿しない。** `report` の `operations.publishUnknown` に一覧が出る。Threadsのプロフィール（またはread権限のAPI）で承認済み本文を探し、見つかれば `{"action":"resolve_publish","postId":…,"outcome":"published","externalPostId":"<id>"}`、ないことを確認できたときだけ `"outcome":"not_published"`（postが `approved` に戻る）。その後の再公開はオーナーの明示承認で `publish_post`。応答に `externalPostId` が含まれる場合（Threadsは受理したが記録に失敗）はそのIDで照合する。
- `import_posts` は1ページずつ（nextCursorを明示的に続ける）。`collect_*` の過去値を再現・捏造しない。時刻を逃した観測は欠測のまま。
- cron: 日次purge、24/72/168h到達の投稿を最大3件、日次account snapshot。投稿探索は直近170h・250件まで（それを超える運用は再設計）。
- 週次: read-only `report` → 母数・欠測・成熟を確認 → 仮説は最大2つを `ops/experiments/` に → 承認範囲のdraft。外部で行った分析・下書きは `record_external_run` で開始/終了/既知の費用だけ申告（内容は送らない。プロバイダー実測と区別される）。

## 8. 法務・窓口（無料β公開の前提、未作成 = BLOCKED）

この文書群は実装方針であり法務文書ではない。仮の文面・架空の連絡先を公開しない。公開前にオーナー（必要なら専門家）が用意し、`/login` からリンクする:

- プライバシーポリシー: 取得するデータ（Googleの基本プロフィール、90日の運用台帳とHMAC fingerprint、任意計測、課金台帳）、保存しないもの（相談・鑑定本文・出生情報・日誌）、委託先と保存国（Supabase・Vercel・Google）、保持期間（DATABASE.md §保持）、同意の撤回・エクスポート・削除の方法、削除後も残る非識別の課金記録、子どもの利用、問い合わせ先。
- 利用規約: 娯楽・内省目的で予測ではないこと、Free/Trialの内容（無料βではPremium・課金なし）、禁止行為、免責、準拠法。
- 問い合わせ窓口: 実在するメールまたはフォーム、応答目安、権利行使（開示・削除）の受付。
- 有料公開時に追加: 特定商取引法に基づく表記（日本の事業者の場合）・返金/解約規約・税表示（[BILLING_PROVIDER.md](BILLING_PROVIDER.md)）。
