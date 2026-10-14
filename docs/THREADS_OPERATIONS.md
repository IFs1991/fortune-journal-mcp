# Threads P0 operation runbook

運営者自身の1アカウントを対象にする。顧客のThreads連携機能ではない。顧客用MCPに運営ツールを混ぜない。

## 接続前提

Meta公式文書で対象API版と`threads_basic`、Insights用`threads_manage_insights`、公開用権限を確認して取得する。必要なアプリ審査・tokenの更新/失効・対象accountを実機で検証。ソース内にtokenを保存しない。自動token refreshは未実装であり運用監視項目。

`THREADS_API_VERSION`は明示。公式例のv1.0を最新と断定してハードコードしない。全リクエストはgraph.threads.net固定、tokenはAuthorization header、外部next URLを直接followしない。実API未実行であり、期間・応答shape・公開containerの挙動はStagingで確認が必要。

## 許可するcommand

`node --env-file=.env.local --experimental-strip-types scripts/ops.mjs ops/examples/draft-post.json`

- draft_post：投稿を固定IDで保存。内容とハッシュを返す。
- approve_post：返されたpostId＋本文SHA-256だけを承認。文面が変わったら再承認。
- publish_post：追加のTHREADS_PUBLISH_ENABLED、承認、schedule到達を確認して1回実行。
- import_posts：取得できる過去投稿の1ページを読む。nextCursorを明示的に続行。既存外部IDは重複しない。
- collect_post_metrics：手動またはbackfill_now。過去24hの値を再現しない。
- collect_account_metrics：followersはsince/untilなし。他は指定期間。混合sumしない。
- report：成熟コホート、24h投稿、MRR・現金・7日followers・run状態/観測済み費用。raw顧客一覧は返さない。
- referral_link：公開投稿だけに署名linkを発行。購入誘導はホストのポリシーを確認。
- record_external_run：外部の所有者エージェントによる分析/下書き実行を、開始/終了/成功失敗と既知のコストだけ報告。内容本文は送らない。外部申告であってプロバイダー実測とは区別。
- record_run_cost：既存runのモデル等を外部申告として追記。実API計測済みと称さない。

requestIdを新しくしただけで公開の再試行を許可しない。公開冪等性はpostIdで固定。runの再試行回数はDBで管理。可観測性は任意の業務活動すべてを完全捕捉するものではない。外部Claude Codeによる分析/投稿案生成の実行はrecord_external_runで申告できる。分析内容と仮説は後述experiment artifactに残す。

## 公開結果不明

API応答がない、DBへの確定書込に失敗した、leaseが切れた場合はpublish_unknown。**自動再投稿しない**。投稿一覧と既知のcontainerを照合し、外部に公開済みか確認する。`fj_finish_publish`の確定はservice_roleを使う承認済み保守手順だけ。UIに「再試行」を安易に足さない。投稿IDだけで全文が一致したと推測しない。

未公開が確認できても、旧post/runの監査を残し、明示承認付きで新しいpostとして作り直す。外部サービスとのexactly-onceは保証しない。

## Hourly maintenance

vercel.jsonは毎時15分の認証付きmaintenanceを定義する。日次purge、24/72/168hに到達した投稿最大3件、日次account snapshotを実行。**自動公開は含まない。** 初期28投稿規模の上限で、250投稿探索上限/2h窓を超える運用は再設計する。

収集失敗はrunと戻り値に残す。cronが200でもresults中に失敗があり得るため監視する。最低限、24h以上の収集停止・unknown公開・失敗run増加を通知。通知destinationは未接続でありDoD未完了。時刻を逃したら欠測として残し、遡って値を捏造しない。

## 14日実験

1日2本/14日=28本は仮計画。まずテーマ×表現の2軸、占術/時間帯/言語をできるだけ固定。因果推論や有意差を断定せず、次の試験仮説を作る。`ops/experiments/experiment-template.json`を使い、分析でpostの実測属性を改ざんしない。
