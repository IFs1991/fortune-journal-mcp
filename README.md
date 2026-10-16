# Fortune Journal MCP

英語圏向けの小型占術MCPサーバー（TypeScript / Next.js on Vercel / Supabase）。顧客のChatGPT・Claudeが会話を、顧客自身のGoogle Sheetsが手帳を担当し、このサーバーは数秘術とタロットの決定的計算と利用権の管理だけを行う。鑑定本文・相談・出生情報・日誌は保存しない。

**状態: v0.3.0、ローカルでDeploy-Ready。Staging未作成、未公開。** 判定と根拠は [docs/DEFINITION_OF_DONE.md](docs/DEFINITION_OF_DONE.md)。

## 最初に読むもの

| ファイル | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | ルールの正本（承認境界・不変条件・変更手順・報告） |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 構成図、レイヤー、7ツールとリクエスト経路 |
| [docs/DATABASE.md](docs/DATABASE.md) | 表・RPCの設計理由。現在の完成形は [docs/generated/DB_CATALOG.md](docs/generated/DB_CATALOG.md)（生成物） |
| [docs/SECURITY.md](docs/SECURITY.md) | 認証・権限・データ境界・残留リスク |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | ローカル検証、Staging構築、デプロイ、監視、復旧、Threads運営 |
| [docs/DEFINITION_OF_DONE.md](docs/DEFINITION_OF_DONE.md) | 現在の状態とgate |

その他: [KPI定義](docs/KPI_DICTIONARY.md) · [性能測定](docs/PERFORMANCE.md) · [課金adapter方針](docs/BILLING_PROVIDER.md) · [plugin提出](docs/PLUGIN_SUBMISSION.md) · [出典](docs/SOURCES.md) · [変更履歴](docs/CHANGELOG.md)

## ローカルで動かす

```bash
npm ci
npm run release:check                      # format・static・unit・typecheck・build・使い捨てPG・schema差分・audit
supabase start --network-id fj_local_net   # 専用ローカルstack（project_id fortune-journal-local、554xx）
npm run test:db:supabase                   # 実SupabaseイメージでSQLスイート
```

E2E・ベンチマークの手順は [docs/OPERATIONS.md](docs/OPERATIONS.md) §1。リモート（Supabase/Vercel/Google/Meta）への書込みは承認制（AGENTS.md §2）。**mainへのmergeはVercel Production deployになる。**

## 配置

```text
app/                 HTTP入口だけ（/api/mcp, /api/ops, /api/cron, /api/account, /login, /oauth/consent）
src/mcp/             顧客向け7ツール（tools.ts が一覧、schemas.ts が入出力契約）
src/ops/             運営者専用API（commands.ts が一覧）: 投稿・Insights・run履歴・レポート・保守
src/account.ts       同意設定・エクスポート・アカウント削除
src/domain/          純粋ロジック（数秘術・タロット・journal・OAuth claim・HMAC・Threads正規化）
src/integrations/    Threads API client
src/lib/             設定・秘密・Supabase client・bearer検証・計測
supabase/migrations/ 唯一の適用元（baseline 1本）。schema.sql は生成物
supabase/tests/      SQLスイート（権限・計算・同意・課金・運営・保持）
scripts/             テスト・E2E・ベンチ・schema生成・運営CLI
ops/                 運営専用スキル・コマンド例・実験記録（顧客pluginに含めない）
skills/              顧客用スキル
verification/        実行証拠（実行したものだけPASS）
```

## 商品仮説（コード上の正本は `fj_record_calculation`）

Free: 数秘術3回/ISO週（タロットなし）。Trial: 初回計算から14日、各100回/UTC日。Premium: 各200回/UTC日（検証済み契約のみ、決済は未接続）。数値は仮説で、AIから変更できない。
