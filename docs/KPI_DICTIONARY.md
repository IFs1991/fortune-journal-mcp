# KPI dictionary

目的：投稿の閲覧数そのものではなく、最初の価値体験・再利用・継続課金を改善する。現時点で実ユーザーのベースラインはない。率の目標・勝敗は設定していない。

## 優先3KPI

|指標|分子 / 分母|期間・除外|SQLと限界|
|---|---|---|---|
|初回鑑定完了率24h|登録後24h以内にMCP計算成功 / 24h経過した対象登録者|near-signupで任意同意した登録コホート|fj_cohort_report。サーバー計算成功であり画面表示/保存の確認ではない|
|D7再利用率|初回計算から[7日,8日)に再計算 / 初回から8日経過した対象初回利用者|UTC絶対時間、8日未満を分母に入れない|fj_cohort_report。within7dayと混ぜない|
|35日有料転換率|登録後[0日,35日)に正額の検証済み課金 / 登録から35日経過した対象登録者|Trialは課金に含めない。初回返金を勝手に除かない|fj_cohort_report。グロス転換率、返金は別guardrail|

全て**同意したnear-signup登録者だけ**。全訪問者や全登録者の率として表示しない。古い利用者が後日同意した場合はanalytics_enrolledとして残すがregistrationを遡って捏造しない。撤回するとコホートから消え、過去の集計が変わる。これも限界として記す。

## P0 driver / cost guardrails

- **24h反応率**：(likes+replies+reposts+quotes)/views*100。同一人の複数反応があるためユニーク率ではなく、100%を超える場合も切り捨てない。sharesは収集するがこの定義の分子に入れない。
- 比較に使うのは実際の年齢24–26hのscheduled snapshotだけ。近い観測1件を選ぶ。欠測・views0・分子の一部NULLは率NULL。全投稿平均を求めるなら「投稿別率平均」と「合算反応/合算views」を区別。
- **7日フォロワー純増**：期間末の時点値−7日前の時点値。各端点直前26h以内の最も新しい観測を使い、実観測時刻とactualDaysを返す。ない端点はNULL。負の増加も保存。
- **run失敗・unknown率**：task別にsucceeded/failed/unknown/runningを分ける。retry率は(attempts>1)のrun率。publish_unknownを成功・0・再投稿済みにしない。
- **費用**：自社が使ったモデル/トークン/金額＋cost_source。unobservedはNULL。coverage=費用観測済run/対象run。顧客側モデル費用は算定対象外。自社の推論費が発生したことを自動推定しない。

## 課金指標

- `fj_cash_events` / `fj_revenue_report`：検証済み正額paymentと返金/chargebackを符号付きminor unitで集計。通貨＋exponentごと。入金額は税抜売上・利益を意味しない。
- `fj_current_mrr`：verified、active、期限未来、金額/通貨/intervalが既知の契約のみ。年払いは12等分。返金1件をMRRからそのまま引かない。為替換算せず通貨ごと。
- 有料更新率は初回positive paymentと2回目recurring paymentを契約単位で対応させ、更新期日を過ぎた契約を母数にする。現段階の汎用adapterだけでは正しいdue dateを保証できないため、**支払事業者確定後に実装・検証する公開gate**。
- 粗利/LTVはプロセッサー手数料、税の扱い、インフラ費、支持費、継続コホートがない間は計算しない。単にMRR/解約率を確定LTVと呼ばない。

## Attribution

登録イベントに署名リンク（source_evidence=signed_link）か本人申告を付ける。post_id→fortune_posts→experiment_id/variantに追える。unknownをdirectに置き換えない。MCP clientは接続の証拠であって流入の証拠ではない。

## Review cadence

週次は1–3の主指標＋24h反応・follower・run失敗/費用を確認する。n、対象期間、成熟分母、観測欠落を併記する。28投稿の実験で4因子を同時に勝者判定しない。仮説は別ファイルに記録し、観測値を書き換えない。
