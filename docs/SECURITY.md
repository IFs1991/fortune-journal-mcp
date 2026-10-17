# Security and data boundaries

不変条件の正本は [AGENTS.md](../AGENTS.md) §3。ここは仕組みと残留リスク。

## 認証

- **Webログイン**: Supabase Auth のGoogleのみ（Email/Password/OTP/Anonymousは無効、ローカルE2Eで拒否を確認）。Drive/Sheets scopeを要求しない。
- **MCP接続**: Supabase OAuth 2.1 server（PKCE S256、DCR）。同意画面 `/oauth/consent` はclient名・callback host・要求scopeを表示し、`MCP_CLIENT_NAMES_JSON` に登録したclient_id以外は「unverified」と警告する。approve/denyは下記のWebセッション境界を通る。redirect先はSupabaseが返すURLだけ。

### 2種類のトークンと境界（2026-10-17 修正）

| | ブラウザセッション | MCP OAuth access token |
|---|---|---|
| 発行 | 本人のブラウザでGoogleログイン → `/auth/callback` のPKCE code交換 | AI app（DCR client）が同意後に `/auth/v1/oauth/token` |
| claim | `aud="authenticated"` のみ、`client_id` なし、`session_id` | `aud="urn:fortune-journal:mcp"` のみ（Custom Access Token Hook）、`client_id` |
| 使える場所 | `/login`・`/oauth/consent`・`/api/account/*`・`/api/oauth/*` | `/api/mcp` だけ |
| 追加の証明 | `/auth/callback` だけが発行するHttpOnly binding cookie（`WEB_SESSION_HMAC_KEY` のHMAC(user, session_id)、`__Host-` prefix、SameSite=Lax） | Origin/Host検証、レート制限 |

- **修正前の不具合（ローカル再現済み）**: Web APIは `getUser()` が通るcookieなら何でも受理していた。MCP用のOAuth access/refresh tokenを持つ（悪意ある）AI appは、それをSupabase cookie形式に詰め、`Origin` を偽装して本人のエクスポート・同意変更・接続解除・アカウント削除を呼べた（`export with forged cookie: 200`）。
- **現在のWeb側判定**（`src/lib/web-session.ts`、fail closed）: ① cookieのaccess tokenを `getUser(token)` でSupabase Authが検証（署名・セッション・アカウント存続）→ ② 同じtokenのclaimが**ブラウザセッション型**（`aud` が `authenticated` だけ、`client_id` 不在、`session_id` がUUID、匿名でない、issuer・sub一致）→ ③ binding cookieが当該user+session_idのHMACと一致。どれかが欠ければ未ログイン扱い。Bearerヘッダはこれらのrouteで一切読まない。
- **CSRF**: cookie認証のPOSTは `Origin` 完全一致（欠落は拒否）、`Sec-Fetch-Site` があれば `same-origin` のみ、本文は `application/x-www-form-urlencoded` のみ（上限4–8KiBのストリーム読取り）。エクスポートGETは `Sec-Fetch-Site: cross-site/same-site` を拒否。ユーザーIDは常に検証済みセッションから（クエリ・本文のuser_idは無視、E2Eで確認）。
- **リダイレクト**（`safeNextPath`）: 解析して再構築。結果は `/oauth/consent?authorization_id=<[A-Za-z0-9_-]{5,256}>` か `/login` だけ。TAB/CR/LF・`\`・制御文字・非ASCII・`%2F`/`%5C`/二重エンコード・scheme・余分なパラメータは `/login`（修正前は `/\t/evil.example` が `https://evil.example` に解決された）。OAuthのstate/PKCEはSupabaseとclientの間で完結し、このパスに依存しない（E2Eでcallback・state一致を確認）。

### MCP bearer検証（`src/lib/oauth.ts`、毎リクエスト）

1. **Origin/Host**（認証より前、`src/lib/urls.ts` `mcpRequestCheck`）: `Origin` があり `APP_ORIGIN`・`MCP_ALLOWED_ORIGINS` 以外なら403（有効なbearerでも）。Originなし（ChatGPT/Claude等のサーバー側接続）は仕様どおり許可。`Host` が `APP_ORIGIN` のhost以外なら421（DNS rebinding）。本文64KiB上限（413）。
2. レート制限（下記）。
3. 未検証payloadの事前検査（拒否専用）: issuer完全一致、**`aud` がちょうど `urn:fortune-journal:mcp`**、role、sub形式、client_id、exp。
4. `auth.getUser(token)`: 署名・セッション・アカウント存続（接続解除・削除後は即401）。
5. 検証済みuserとsub一致を含む同じclaim照合。

401の `WWW-Authenticate` の `resource_metadata` は `APP_ORIGIN` 固定（転送ヘッダを信用しない）。

### トークンaudience（MCP仕様 / RFC 8707）— 部分的に解消

MCP authorization仕様（2026-07-28）は「MCP serverはaccess tokenが自分をaudienceとして発行されたことを検証しなければならない」と定める。ローカル実測（Supabase CLI 2.120.0、2026-10-17）:

- Supabase OAuth 2.1 serverは `resource` を受け付けても `aud` を常に `authenticated` にする。AS metadataに `resource_indicators_supported` はない。
- **Custom Access Token Hook は使える**: hookにはOAuth clientのtokenが `client_id` 付きで渡り（`authentication_method = oauth_provider/authorization_code`、refresh時は `token_refresh`）、`aud` を書き換えても `getUser()`・refresh・revokeは動く。ただし**hookの入力に `resource` パラメータは含まれない**（`claims, user_id, metadata, authentication_method` のみ）。

採用した方式: `public.fj_access_token_hook`（純関数、`supabase_auth_admin` と service_role だけがEXECUTE）が `client_id` を持つtokenの `aud` を `urn:fortune-journal:mcp` だけに置き換え、`/api/mcp` はそれ以外を拒否する。ブラウザセッションtokenは変更しない。これで「このMCP server向けに発行されたtokenだけを受理」は満たす（別issuer・ブラウザtoken・hook無効環境のtokenは401、E2E確認済み）。

残る差（仕様準拠の観点で明記）: AS側で `resource` ごとにaudienceを束縛するRFC 8707の挙動ではない。同じSupabase projectのOAuth clientはすべて同じaudienceを得るので、**projectをこのMCP専用に保つことが前提**（Staging/Productionで別project、他のOAuth resourceを同居させない）。Supabaseがresource indicatorsに対応したら、hookをやめてAS発行のaudに切り替える。hookはStaging/ProductionのAuth設定で有効化が必要（無効ならMCPは全401 = fail closed、smokeで検知）。

### レート制限（`src/lib/rate-limit.ts`）

インスタンス内の固定窓（Redisなし）: `/api/mcp` は送信元600/分・bearer 120/分、ブラウザ系route（callback・同意・解除・account）は送信元120/分。超過は429 + `Retry-After`。Fluid computeでインスタンスが共有される範囲の上限であり、全体の上限は **Vercel Firewall のrate limit rule**（`/api/mcp`・`/auth/callback`・`/api/oauth/*`・`/api/account/*`、未設定 = BLOCKED、[OPERATIONS.md](OPERATIONS.md) §3.3）。利用回数のquotaはDB（`fj_record_calculation`）。

- 接続解除: `/login` → `/api/oauth/revoke` → `revokeGrant`。既存access tokenも次の `getUser()` で401（E2E）。

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
- 削除: 有効な課金契約があれば拒否 → 停止 → 全セッション失効 → Authユーザー削除（CASCADE）。途中で失敗しても停止済みなのでMCPは使えない。顧客のGoogleファイルは削除しない。課金bindingと台帳は `user_id`・顧客IDをNULLにして残る（削除後の返金・CBを記録するため）。
- Vercel・Authのログが残る可能性はある。リクエストbodyログ・エラー全文を出さない。

## 残留リスク

- service_role鍵や `OPS_HMAC_KEY` の流出は全権に等しい。環境ごとに分離し、Vercel Sensitive env・失効手順をStagingで確認する（BLOCKED: Staging未作成）。
- アプリ内レート制限はインスタンス単位の最善努力。全体のrate limitはVercel Firewallで設定する（未設定）。
- 送信元アドレスはVercelのedgeが付ける `x-real-ip` / `x-forwarded-for` を使う。Vercel以外の前段では偽装可能。
- audienceはhookで制限済みだが、AS側のresource束縛ではない（上記）。DCRは2026-07-28仕様で非推奨（CIMDが推奨）。SupabaseのCIMD対応は未確認。
- `WEB_SESSION_HMAC_KEY` を変えると全ブラウザがaccount画面から未ログイン扱いになる（MCP接続は影響なし）。漏えい時はローテーションする。
- 法務（プライバシー通知、保存国、委託先、権利対応窓口）は未確定。この文書は実装方針であり法務審査済みではない。
