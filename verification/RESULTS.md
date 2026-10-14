# Verification results — 2026-10-15 / v0.2.1 (commit b0def30 + evidence)

> コミットIDについて: 検証は作者情報の書き換え前に実行した。書き換えで内容（tree）は変わらずIDだけが変わったため、旧 `64de536` = 現 `b0def30`。生ログ（`npm_ci_clean_clone.log` 等）はコマンド出力のまま残しており、旧IDが表示される。

このファイルは**実行したものだけ**をPASSとする。command・exit code・開始時刻・環境は [results.json](results.json)、出力は同名ログ。
環境: Windows 11 + Git Bash、Node 22.22.2、npm 10.9.7、Docker 29.8.2、Supabase CLI 2.120.0、psql 17.11。
「local stack」= Supabase CLIのローカルstack（`supabase/postgres:17.6.1.x` + GoTrue v2.197.0 OAuth 2.1 server + PostgREST、project_id `fortune-journal-local`）。リモートのSupabase/Vercelには一切書き込んでいない。

| 検証 | 結果 | 範囲 / 証拠 |
|---|---|---|
| `npm ci`（fresh clone） | **PASS** | lockfileから再現、0 vulnerabilities、39 tests、typecheck、db:check-prepared — `npm_ci_clean_clone.log` |
| Node単体テスト | **PASS 39/0** | 占術、日付、URL/Origin、HMAC、OAuth claim、journal契約、指標、課金正規化、mock Threads — `unit.log` |
| 静的契約 | **PASS** | 11表RLS、5テンプレート+forward-fix 2本のhash、7ツール、禁止列、flags既定OFF — `static.log` |
| full TypeScript | **PASS** | `tsc --noEmit` — `typecheck.log` |
| Next production build | **PASS** | env未設定でも成功 — `production_build.log` |
| npm audit | **PASS 0件** | `audit.log` |
| syntax / pure-domain types / shell | **PASS** | `syntax.log`, `pure_types.log`, `shell_syntax.log` |
| migration整合 | **PASS** | 旧migration sha256一致、CLI生成5本=テンプレートhash、06/07はmanifest登録hash一致、未登録なし — `migration_prepare.log` |
| 使い捨てPostgres 17（fresh / v0.1 upgrade） | **PASS** | 8 migration適用、全SQLスイート、10並列: 別request→3 OK + 7 LIMIT、同一request→1 + 9 replay（同一readingId）、旧データ保持・偽verifiedなし — `db.log` |
| 実SupabaseイメージでのSQLスイート | **PASS 7/7** | rls_security / v02_security / v02_transactions / v02_billing / v02_retention_kpis / v02_negative_edge / v02_forward_fix_06 — `supabase_local_sql.log`, 適用ログ `supabase_local_start.log` |
| `supabase db lint`（local） | **PASS** | No schema errors — `supabase_lint_local.log` |
| `supabase db advisors`（local） | **PASS（WARN/ERROR 0）** | INFOのみ: 運営表のRLS no-policy（意図的deny-all）、新規DBの未使用index — `supabase_advisors_local.log` |
| E2E local（analytics/ops OFF） | **PASS 17/17** | `e2e_local.json`, `e2e_local.log` |
| E2E local（analytics/ops ON） | **PASS 18/18** | `e2e_local_analytics_ops.json`, `e2e_local_analytics_ops.log` |
| Vercel runtime / Staging Supabase | **BLOCKED** | 専用projectが存在しない（下記）。作成・deployは承認待ち |
| 実Googleログイン / ChatGPT・Claude実ホスト | **BLOCKED** | Staging公開URLとGoogle OAuth clientが必要 |
| 顧客Google Sheets E2E | **BLOCKED** | 顧客側コネクタでの手動確認。自社MCPはGoogleに触れない |
| Meta Threads実API | **BLOCKED** | 権限・API版未確認、全flag OFF |
| 決済 | **BLOCKED** | 事業者未確定、webhook 501（E2E/smoke確認） |
| GitHub Actions CI | **NOT RUN** | workflowはYAML検証済み、Action pinはtag refと照合済み。remote未設定 |

E2Eの内訳（両モード共通）: Google以外のログイン拒否（signup/password/OTP/anonymous）・anonのData API全拒否・DCR+PKCE（誤verifier拒否、code再利用拒否）+同意画面（client名・callback host・unverified表示・Origin/セッション必須）・ブラウザセッションJWTとゴミtokenは401+RFC 9728 discovery・tools/list 7件（`_meta.securitySchemes`/outputSchema）・`initialize`と2026-07-28 envelopeの両プロトコル・初回計算でTrial開始（ログイン/同意では開始しない）・同一requestId replay/別入力conflict・日付越えtarot replay・Free 3回/ISO週・Free tarot拒否・A/BのRLS分離と自己昇格拒否・本人export（fingerprint/出生日なし）・refresh・revoke後にaccess/refresh失効・deny→`access_denied`・cron認証とpurge・署名付きops（無署名/改ざん/期限切れ拒否）・アカウント削除後のtoken失効。ONモードは加えて analytics/interest の別同意、topic gating、feedback/report（他人のreading拒否）、撤回による任意データ削除。

## このセッションで見つけて直した不具合（実行で発見）

1. **P0** `next@15.5.19` に critical advisory（RCE/SSRF/cache confusion等） → 15.5.27 + postcss/sharp override。
2. **P0** MCP routeが `@modelcontextprotocol/server` v2 / `mcp-handler` v2 で型エラー（`securitySchemes`、旧3引数 `createMcpHandler`）→ 現行APIへ修正。
3. **P0** `fj_set_privacy` が service_role で `auth.users` を読む → 実Supabaseでは初回の計測同意が必ず失敗。素のPGのstubが実Supabaseにない権限を与えて隠していた → migration 06 + stub修正。
4. **P1** 同意画面が「後で解除可能」と書くのに解除UIがない → Connected AI apps + revoke。
5. **P1** DCRのclient名は自己申告 → unverified表示。`resource_metadata` がForwarded headerで偽装可能 → `APP_ORIGIN`固定。
6. **P2** advisorsのunindexed FK 3件 → migration 07。cron失敗が無ログ → 構造化ログ。`check-pure-types` がWindowsで失敗 → 修正。

## Remote read-only inventory（2026-10-15、書込みなし）

- Supabase MCP / Vercel MCP: このセッションでは未認証のため未使用。代わりにCLIのread-only一覧を使用。
- Supabase（CLIログイン済み）: projectは `seikotsuin-management`、`tiramisu-works-studio`（ACTIVE）、`exbition-meeting-manager`（INACTIVE）のみ。**Fortune Journal用projectなし**。どれもlink・変更していない。
- Vercel（CLIログイン済み、team「Toshu's projects」）: Fortune Journal名のprojectなし。`uranai` というprojectがあるが、名前からの推測で対象にしない。
- 副作用の申告: `vercel projects ls` 実行時にVercel CLIが自身のClaude pluginを自動更新した（CLIの挙動。プロジェクトやデプロイへの変更ではない）。
- ローカルDocker: 他プロジェクトのSupabase stack（Tiramisu等）が稼働中。停止・削除・network変更はしていない。本プロジェクトは専用network `fj_local_net`（10.253.17.0/24）を新規作成して使用。

## 公開前の順番

Staging作成の承認 → Supabase専用project + Auth設定（Googleのみ、OAuth Server、非対称鍵）→ `db dump` → `db push --dry-run` → 承認 → `db push` → advisors → Vercel専用project + env → Preview deploy（承認）→ Staging E2E（実Google・Claude/ChatGPT・MCP Inspector・Sheets手動）→ P1判定。Meta・決済は別gate。
