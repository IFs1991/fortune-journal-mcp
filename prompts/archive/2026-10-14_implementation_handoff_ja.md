このリポジトリのAGENTS.md、README、docs/BUILD_STATUS.md、docs/UPGRADE.md、docs/DEFINITION_OF_DONE.mdを最初に読んでください。

今回の目的はv0.2ソースをStagingで検証可能な状態にすることです。まず継承済みの依存pinの実在と互換性を公式registryで確認し、lockfileを確定してください。次に実Supabase CLIで5本のテンプレートを正式migration化し、新規/旧データ入りの使い捨てDBでRLS・並列quota・課金順序・保持期限をテストしてください。元migrationは変更禁止です。

単体テストの成功をfull buildやDB成功に読み替えないこと。修正は最小限にし、API/RPC/DoDを一緒に更新してください。Google/MCP OAuth、Google Sheets、Threads実APIは別途実機で確認が必要です。

本番デプロイ、実投稿、課金有効化、Worksの変更、秘密値の出力、破壊的DB操作は行わないでください。最後に実行コマンド、合否、変更点、未完了gateをverificationへ記録してください。
