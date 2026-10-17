# Billing adapter — intentionally disabled

**決済会社は未確定／占い業種の承認なし。** `/api/billing/webhook`は501を返し、決済成功やPremiumを偽装しません。BPMその他をこの成果物で選定・接続したとは扱わない。

提供済み：`fj_apply_billing`（正規化イベントの検証・重複/経済キー/順序制御・snapshot適用を1トランザクション）、`billing_events` 台帳、cash/MRR集計（`supabase/tests/billing.sql`）。TypeScript側のadapter interfaceと正規化関数はv0.3.0で削除した（未接続のまま重複した検証を持たないため）。事業者が決まったら、署名検証→事業者APIでの照合→`fj_apply_billing` の入力形（キー: `event_type`, `provider_subscription_id`, `occurred_at`, `economic_key`, `original_payment_key`, `amount_minor`, `currency`, `currency_exponent`, `billing_reason`, `plan_key`, `subscription{status, provider_updated_at, current_period_end, cancel_at_period_end, plan_key, amount_minor, currency, currency_exponent, interval_months}`）への変換をadapterとして実装する。

## 正しい順番

1. 実サービス（AI占術MCP・英語圏・少額継続）を開示して業種・通貨・継続・API・返金・解約の受入れ確認。
2. ホストの販売導線制限・販売主体・税/手数料・保存方針を確認。
3. checkout前にサーバーがuserとprovider customer/subscriptionを結び付ける。Webhook metadataのuser_idを信用しない。
4. **生bodyから署名検証**→provider APIから必要な契約snapshot照合→allowlist正規化→1DB transaction。イベントIDと経済事象IDは別。
5. 通知逆順・重複・同時・部分返金・chargeback・失敗課金・解約予約・期限切れをsandboxでテスト。
6. hosted billing portalか同等の顧客セルフ解約と、通知取りこぼしの定期照合、再課金防止を実装。

台帳は金額を整数minor unit＋currency＋exponentで保存。499 centsはUSD4.99、JPY499は499円。通貨を無換算合算しない。cashとMRRを別にする。

payment単体でactiveにしない。検証済みsubscription snapshotだけから権限を更新する。古いsnapshotは巻き戻さない。

`fj_apply_billing` の規則（`supabase/tests/billing.sql` と `scripts/test-db.sh` の並列テストで検証）:

- 同じevent id: 同一内容は何もしない、異なれば `BILLING_IDEMPOTENCY_CONFLICT`。
- 別event idの同じ入金（`economic_key` 一致）: cashは二重計上しないが、その通知が持つ**より新しいsnapshotは適用する**（2026-10-17修正前は無視していた）。
- 同じ `provider_updated_at` で内容（status・期間・解約予約・plan・金額・通貨・間隔）が違う: `needs_reconciliation`。2つが権限で食い違う場合は `verified_at` をNULLにしてPremiumを止める（fail closed）。adapterは事業者APIから現在のsubscriptionを取り直し、`"reconciled": true` を付けて渡す（同時刻でも適用、過去には戻さない）。
- アカウント削除後もbinding（`user_id`/`provider_customer_id` はNULL）が残るので返金・CBは台帳に入り、cash集計が合う。削除済みbindingを生かし続けるイベントは `needs_reconciliation`（人が返金・解約を確認）。
- `fj_revenue_report` は期間内の `eventsNeedingReconciliation` 件数を返す（運営レポートに表示）。

## 無料βと有料公開の分離

- **無料β（現在可能な範囲）**: Free（数秘術 週3回）＋初回計算から14日Trial（各機能 日100回）。checkoutは存在せず、webhookは501、`/api/health` は `billing: not_connected`。Premiumは検証済みsubscriptionがない限り付与されない（DBの `fj_access_status` が唯一の規則）。MCPツール出力に価格・購入導線を出さない。
- **有料公開に必要**: 事業者決定と業種承認、checkout前のサーバー側binding作成、生body署名検証付きwebhook adapter、sandboxでの支払・権限反映・解約・返金・CB・失敗課金E2E、定期照合、顧客セルフ解約、法務（特商法相当表示・返金規約・税）。上記まで webhookは501のまま（`check:static` が強制）。`billing_events` の行は「署名検証済み」を意味するため、`fj_apply_billing` は検証済みイベントでだけ呼び、service_roleを不正な入力に渡さない。

課金・返金・外部取引IDは金融関連データである。相談本文を持たなくても保持・エクスポート・削除の義務がなくなるわけではない。法定保持は未確定のため自動purgeから除外し、課金開始gateとする。
