# Plugin packaging / host checks

`.codex-plugin/plugin.json`は顧客用packageメタデータ、`.mcp.json`は未デプロイplaceholder。customer skillsは`skills/fortune-journal/`のみ。owner skill/API秘密は登録しない。ここで作成したZIPは、ストアに公開済み／ホスト承認済みという意味ではない。

MCPの機能は7個。既存アカウントに基づく権限制御だけ。tool結果に購入CTAやcheckout URLを追加しない。Free/Trialの有用性を維持し、プラン制約は中立的に説明。OpenAI/Anthropic各ホストの現行ガイドラインで確認してから申請する。

write系annotationは、quota/metadata/feedbackの更新を隠さない。`Read/Write`のmanifest語彙そのものも提出時の最新schemaで検証が必要。official Google connectorが別途必要であること、許可なしにはSheets保存できないことを説明する。

public listingに必要なprivacy/terms/support/developer identity、本番URL、無料機能、実機E2Eを提出前に埋める。仮の連絡先・架空privacy URL・架空の承認実績は載せない。
