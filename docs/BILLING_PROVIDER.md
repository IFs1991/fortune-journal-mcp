# Billing adapter — intentionally disabled

**決済会社は未確定／占い業種の承認なし。** `/api/billing/webhook`は501を返し、決済成功やPremiumを偽装しません。BPMその他をこの成果物で選定・接続したとは扱わない。

提供済み：`src/domain/billing-event.ts`の正規化契約、`src/lib/billing.ts`のadapter interface、`fj_apply_billing`の重複/順序制御、cash/MRR集計。

## 正しい順番

1. 実サービス（AI占術MCP・英語圏・少額継続）を開示して業種・通貨・継続・API・返金・解約の受入れ確認。
2. ホストの販売導線制限・販売主体・税/手数料・保存方針を確認。
3. checkout前にサーバーがuserとprovider customer/subscriptionを結び付ける。Webhook metadataのuser_idを信用しない。
4. **生bodyから署名検証**→provider APIから必要な契約snapshot照合→allowlist正規化→1DB transaction。イベントIDと経済事象IDは別。
5. 通知逆順・重複・同時・部分返金・chargeback・失敗課金・解約予約・期限切れをsandboxでテスト。
6. hosted billing portalか同等の顧客セルフ解約と、通知取りこぼしの定期照合、再課金防止を実装。

台帳は金額を整数minor unit＋currency＋exponentで保存。499 centsはUSD4.99、JPY499は499円。通貨を無換算合算しない。cashとMRRを別にする。

payment単体でactiveにしない。検証済みsubscription snapshotだけから権限を更新する。古いsnapshotは巻き戻さず、同日時に矛盾すればreconciliation_required。SQL上のverified_atは信頼されたadapterが渡すことを前提にするため、service_roleを不正な入力に渡さない。

課金・返金・外部取引IDは金融関連データである。相談本文を持たなくても保持・エクスポート・削除の義務がなくなるわけではない。法定保持は未確定のため自動purgeから除外し、課金開始gateとする。
