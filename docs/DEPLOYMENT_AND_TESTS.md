# Setup / test / deployment

## 準備

新しいVercel / Supabase Stagingを用意する。既存WorksのDB/secretを使用しない。Node22.16以上。ネットアクセスが必要。継承したpackage pinsはこの環境では取得できず未検証なので、公式registryで照合→互換セット固定→lockfile生成→npm ci。ロックファイルを偽造しない。

.env.exampleの秘密を個別に生成し、envにだけ保存。APP_ORIGINは実際のHTTPSオリジン。Google social login、Supabase OAuth認可server、redirect allowlist、asymmetric keys、MCP discovery URL/consent pathを実projectで設定。顧客Drive/Sheets権限は要求しない。

## ソース検証

```bash
npm test
npm run check:static
npm run check:syntax       # インストール済みtypescript、またはglobal TS
npm run check:pure-types   # 純粋domain/integration限定。full checkの代替ではない
npm run typecheck         # 外部依存のインストールが必要
npm run build
```

## DB検証

```bash
supabase --version
supabase migration new --help
npm run db:prepare
npm run db:check-prepared
npm run test:db
```

DBテストはDockerの使い捨てPostgreSQL17だけ。remote DATABASE_URLは受け付けず、独自に作ったコンテナだけ破棄する。Supabase Authはテスト用stub。実Auth/RLS/JWTは別Stagingで確認する。コンテナdigestは公開前にレビュー済みのものへ固定する。

## Staging

UPGRADEの手順に沿ってSQLを反映、型/ビルド/endpoint smoke後にVercel Preview。MCPの公開URLと`.mcp.json`のplaceholderを置き換え、Google→MCP OAuth→計算→顧客Sheetsまで実行する。Preview保護は任意に解除しない。テストaccountが明示的に許された経路で接続。

最初は全growth flags false。P0はowner opsとinsightsだけtrue、実投稿承認後にpublishを別途true。P1 optional analyticsは告知・本人同意と実privacy tests後にtrue。環境変数切替後のデプロイを確認。payment endpointは501のまま。

## CI

`.github/workflows/ci.yml`はPR/手動でunit、使い捨てDB、full buildを分けて実行する。秘密値は不要。lockfileがなければbuild jobは失敗を明示する。現時点のソースがgreen CI済みだと扱わない。CI成功と本番公開は別操作。

## Release

`npm run release:check`は未準備migrationと未ビルドを拒否。外部E2E結果・target project・commit・env・backup・migration状態を確認してから承認済み手順でdeploy。archive生成はdeployではない。運営APIは公開ネット上にあるためrate limit/鍵分離/失効を確認。
