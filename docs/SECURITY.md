# Security model / release gates

- Google loginはSupabase Auth。MCPには別のOAuthクライアント認可を要求。
- bearerはAuthのgetUserで検証後、issuer/audience/role/sub/client_id/expiryを確認。resource-specific audienceへの対応は実OAuth側の仕様を再確認。共有Supabase projectを使わない。
- service_roleはサーバーのみ。public URL/publishable keyとsecretを混同しない。
- table RLS＋列GRANT。運営表と課金eventは顧客に直接非公開。全fj_RPCはservice_role専用、SECURITY INVOKER／search_path固定。
- 顧客のcookie変更APIはOriginチェック、IDは実Authから。入力にowner/user IDを受け取らない。
- opsには独立HMAC。timestamp±300秒、constant-time比較、body64KiB、query禁止、allowlistのみ。暗号署名は同じ5分以内のread-only再送まで禁止するnonce ledgerではない。永続writeはDBのrequest/post/runキーで冪等性を確保。
- secretsは3種類以上を共用しない。TAROT／REQUESTの鍵変更は再現性/90日dedupに影響し、計画と版変更が必要。
- approvalは投稿bodyハッシュに拘束。本文は運営内容だけ。承認と取得の間で本文が変更されたらclaimを拒否。
- Meta呼出しは固定origin、redirect:error、Authorization header、pagination cursorのみ。原文provider error、access token、顧客inputをログに出さない。
- Payment provider未承認。webhookは501で停止。生署名未検証のデータから台帳や権限を変えない。
- スプレッドシートtextはuntrusted、式注入escapeは顧客用手順に残す。正しいGoogle connector権限と書き込み承認は別途必要。

## 残留リスク

RLSはservice_role流出を防がない。HMAC secret流出は運営コマンド全権に相当する。接続環境ごとに鍵を分離し、secret管理・アクセスログ・失効・バックアップ・監視を実機で検証する。匿名公開エンドポイントへのレート制限はVercel側の設定確認が必要。依存の重大脆弱性と全OAuth/CSRF経路は未検証で、公開ブロッカー。

削除後のJWTは単にAuthユーザーを消しただけで即失効するとは限らない。この実装は利用停止とsignoutを先に行い、毎リクエストのgetUser/台帳チェックを行う。接続解除・token refresh・削除直後アクセスのE2Eで確認する。
