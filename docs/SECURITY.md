# Security model / release gates (v0.2.1)

- Google loginはSupabase Auth（Email/Password/OTP/Anonymousは無効、ローカルE2Eで拒否を確認）。MCPには別のOAuth 2.1クライアント認可（Supabase OAuth Server、PKCE S256）を要求する。
- `/api/mcp` のbearerは、①未検証payloadの issuer / aud / role / sub形式 / client_id / exp が不正（期限切れ・他issuer・ブラウザセッションJWT）ならネットワーク前に拒否（拒否専用。受理には必ず②③が必要）→ ②`auth.getUser` で署名・セッション・アカウント存続を検証 → ③`src/domain/oauth-claims.ts` で issuer / aud=`authenticated` / sub一致 / role=`authenticated` / client_id / exp を検証（unitテスト）。ブラウザセッションJWT（client_idなし）は401（E2E）。
- Supabase OAuthのaccess tokenはresource固有audience（RFC 8707）を持たない。**このアプリ専用のSupabase projectを使う**ことでaudienceの混同を防ぐ。共有projectは不可。
- 401の `WWW-Authenticate` は `resource_metadata` を `APP_ORIGIN` に固定（`X-Forwarded-Host` 偽装を無視、smoke確認）。PRM `/.well-known/oauth-protected-resource[/api/mcp]`。
- 同意画面: client名、callback host、要求scopeを表示。Dynamic Client Registrationのclient名は自己申告のため、`MCP_CLIENT_NAMES_JSON` に登録されたclient_id以外は「unverified」と表示して警告する。approve/denyは同一Origin POST + セッション必須。redirect先はSupabaseが返すURLのみ（POST bodyから受け取らない）。他ユーザーのauthorization_idは操作不可（E2E）。
- `getClaims()` 等のローカル署名検証だけで受理する方式は採らない: 署名が正しくても接続解除・アカウント削除後のセッションを検出できず、失効が最大でアクセストークン有効期限（`jwt_expiry` 3600秒）まで遅れるため。比較と判断は [PERFORMANCE.md](PERFORMANCE.md) §2。
- 接続解除: `/login` の Connected AI apps → `/api/oauth/revoke`（同一Origin POST）→ `supabase.auth.oauth.revokeGrant`。当該clientのセッションとrefresh tokenが失効し、既存access tokenも次の `getUser` で401（E2E）。RFC 7009 revocation endpointはSupabase AS metadataに広告されていない。
- service_roleはサーバーのみ。public URL/publishable keyとsecretを混同しない。
- table RLS＋列GRANT。運営表と課金eventは顧客に直接非公開。全fj_ RPCはservice_role専用、SECURITY INVOKER／`search_path=''`。auth schemaへの追加GRANTはしない（06の修正方針）。
- 顧客のcookie変更APIはOriginチェック、IDは実Authから。入力にowner/user IDを受け取らない。
- opsには独立HMAC（method/path/timestamp/body）。timestamp±300秒、constant-time比較、body64KiB、query禁止、allowlistのみ（E2Eで無署名・改ざん・期限切れを401確認）。nonce ledgerではないため5分以内のread-only再送は防がない。永続writeはDBのrequest/post/runキーで冪等。
- secretsは用途ごとに独立。TAROT／REQUESTの鍵変更は再現性/90日dedupに影響し、計画と版変更が必要。
- approvalは投稿bodyハッシュに拘束。公開結果不明はunknownのまま再投稿しない。
- Meta呼出しは固定origin、redirect:error、Authorization header、pagination cursorのみ。
- Payment provider未承認。webhookは501で停止。
- スプレッドシートtextはuntrusted。`get_journal_schema.writeRules` でRAW書込み/アポストロフィ、record_id重複防止、拒否時に保存したと言わないことを顧客AIへ指示する。
- 依存: next 15.5.27（15.5.19のcritical advisoryを解消）、postcss 8.5.30 / sharp 0.35.5 override、`npm audit` 0件。CIでも `npm audit --audit-level=high`。

## 残留リスク

- RLSはservice_role流出を防がない。HMAC secret流出は運営コマンド全権に相当する。鍵を環境ごとに分離し、Vercel Sensitive env・アクセスログ・失効手順を実Stagingで確認する。
- アプリ内レート制限なし。`/api/mcp`・`/api/ops`・`/oauth/*` はVercel Firewallのrate limitを推奨（未設定）。トークン付きの不正リクエストは1件ごとにSupabase Authへの問い合わせを発生させる。
- MCP SDKのentryはOrigin/Host検証をしない。bearer必須のリモートサーバーでありcookie認証を使わないためDNS rebindingの実害は限定的だが、Firewallでの制限を推奨。
- 実Google、ChatGPT/Claude実ホスト、Staging Supabaseでの同等確認は未実施（DoD: BLOCKED）。
