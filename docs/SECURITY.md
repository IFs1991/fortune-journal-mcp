# Security and data boundaries

不変条件の正本は [AGENTS.md](../AGENTS.md) §3。ここは仕組みと残留リスク。

## 認証

- **Webログイン**: Supabase Auth のGoogleのみ（Email/Password/OTP/Anonymousは無効、ローカルE2Eで拒否を確認）。Drive/Sheets scopeを要求しない。
- **MCP接続**: Supabase OAuth 2.1 server（PKCE S256、DCR）。同意画面 `/oauth/consent` はclient名・callback host・要求scopeを表示し、`MCP_CLIENT_NAMES_JSON` に登録したclient_id以外は「unverified」と警告する。approve/denyは同一Origin POST + セッション必須。redirect先はSupabaseが返すURLだけ。
- **bearer検証**（`src/lib/oauth.ts`、毎リクエスト）: ①未検証payloadの issuer・aud・role・sub形式・client_id・exp が不正なら通信前に拒否（拒否専用）→ ②`auth.getUser(token)` で署名・セッション・アカウント存続 → ③検証済みuserとsub一致を含むclaim照合。ブラウザセッションJWT（client_idなし）は401。`getClaims()` 等のローカル検証だけの受理は採らない（接続解除・削除後も最大 `jwt_expiry` 秒受理されるため。[PERFORMANCE.md](PERFORMANCE.md) §2）。
- 401の `WWW-Authenticate` の `resource_metadata` は `APP_ORIGIN` 固定（転送ヘッダを信用しない）。
- 接続解除: `/login` → `/api/oauth/revoke` → `revokeGrant`。既存access tokenも次の `getUser()` で401（E2E）。

### BLOCKED: トークンのaudience（MCP仕様との差）

MCP authorization仕様（2026-07-28）は「MCP serverはaccess tokenが自分をaudienceとして発行されたことを検証しなければならない（RFC 8707）」と定める。Supabase OAuth 2.1 serverは `resource` を受け付けても **`aud` は常に `authenticated`** で、AS metadataに `resource_indicators_supported` もない（ローカル実測 2026-10-16、`scripts/probe-resource-audience.mjs` → `verification/perf/resource_audience.json`）。

現在の緩和策: このアプリ専用のSupabase project（共有しない）、issuerの完全一致、OAuth client_id必須、毎回の `getUser()`。これで「別のサービス向けのtoken」の混入は防げるが、同じprojectで発行された全OAuthトークンを受理する点は仕様の要求を満たさない。**仕様上は未解決（BLOCKED）として扱う。** 解消条件: Supabaseがresource-bound audienceを提供する、またはclient_idのallowlist運用（DCR/CIMDの実クライアントIDが確定してから）を承認する。

## 権限（DB）

- 全表RLS、anon/authenticatedの表・view・関数権限なし、全関数 invoker + `search_path=''` + service_roleのみ。`supabase/tests/catalog.sql` がpublic schemaの全オブジェクトを検査する（一覧のハードコードなし）。
- service_roleはRLSを迂回するので、アプリは検証済みuser idだけをRPCに渡す。入力・metadataのuser idを使わない。
- 課金: providerのmetadataからユーザーを決めない（サーバー作成のbindingが必須）。金額だけでPremiumにしない。

## 運営API・cron

- `/api/ops`: 別鍵 `OPS_HMAC_KEY` のHMAC（timestamp・method・path・bodyのsha256）、±300秒、定数時間比較、body 64KiB、query禁止、strictなzodコマンド。nonce台帳ではないので5分以内のread-onlyコマンドの再送は防がない（書込みはDBのキーで冪等）。返すエラーコードはallowlistのみ。
- `/api/cron/maintenance`: `Bearer CRON_SECRET`（定数時間比較）。公開処理を含まない。
- 秘密値は用途別に独立（`src/lib/secrets.ts`、32文字以上・placeholder拒否）。TAROT/REQUEST鍵の変更は再現性と重複排除に影響する。

## データの3層（混ぜない）

1. **顧客の手帳**: 出生情報、占い結果、相談・出来事・感想。顧客のAIとGoogle Sheetsだけ。自社は保存もGoogleアクセスもしない。計算入力は一時的に受け取る（「保存しない」と「受け取らない」は別として通知する）。
2. **運用に必要なデータ**: Auth（Googleの基本プロフィールはSupabase Authが保持）、契約、90日のリクエスト台帳、初回利用日時。「個人情報を一切持たない」とは言わない。fingerprintは鍵があれば照合可能な仮名データ。
3. **任意の改善計測**: funnel、固定ラベル評価、本人が選んだtopic。全体スイッチ + 本人同意（topicはさらに別同意）。撤回でイベント・評価を削除しtopicを消す。

採用しないもの: 自由記述フィードバック、悩みの推測・プロファイリング、顧客側LLM費用を0とすること、見ていないSheets保存の成功イベント、未同意の匿名追跡・IP/UA全文・参照元URL全文。流入元は署名リンク（公開post IDと期限だけ、人を追跡するIDなし）か本人申告。接続中のMCP clientは流入の証拠にしない。

## エクスポートと削除

- エクスポート: セッション必須、resource allowlist（prototypeキーを拒否）、100件ページ、`asOf` 固定、fingerprint・token・providerの顧客IDは出さない。
- 削除: 有効な課金契約があれば拒否 → 停止 → 全セッション失効 → Authユーザー削除（CASCADE）。途中で失敗しても停止済みなのでMCPは使えない。顧客のGoogleファイルは削除しない。
- Vercel・Authのログが残る可能性はある。リクエストbodyログ・エラー全文を出さない。

## 残留リスク

- service_role鍵や `OPS_HMAC_KEY` の流出は全権に等しい。環境ごとに分離し、Vercel Sensitive env・失効手順をStagingで確認する（BLOCKED: Staging未作成）。
- アプリ内レート制限なし。トークン付きの不正リクエストは1件ごとにAuth問い合わせを生む。`/api/mcp`・`/api/ops`・`/oauth/*` にVercel Firewallのrate limitを推奨（未設定）。
- MCP SDKはOrigin/Host検証をしない。cookie認証を使わないbearer必須サーバーなのでDNS rebindingの実害は限定的。
- 仕様上のaudience差（上記BLOCKED）。DCRは2026-07-28仕様で非推奨（CIMDが推奨）。SupabaseのCIMD対応は未確認。
- 法務（プライバシー通知、保存国、委託先、権利対応窓口）は未確定。この文書は実装方針であり法務審査済みではない。
