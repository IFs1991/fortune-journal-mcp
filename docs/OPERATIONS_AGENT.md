# Owner agent entrypoint

Canonical rules: ../AGENTS.md. Bounded operator workflow: ../ops/skills/fortune-ops/SKILL.md.

ChatGPT/Claudeで運営する場合でも、秘密値を会話に貼り付けない。ローカルCodex/Claude Code等の認可された実行環境で、envからHMACを読むCLIを使う。運営コネクタを作る場合は別のprivate pluginにし、顧客pluginに含めない。

週次：read-only report → 母数/欠測/成熟の確認 → 投稿テーマ/表現の仮説を最大2つ → owner承認済み範囲のdraft → exact hash承認 → 公開。分析メモはops/experimentsにcommit、実測DBを書き換えない。

復旧：metrics GET失敗は同じrunキーで上限付き再試行。publish_unknownは調査だけ。新IDで勝手に再投稿しない。課金障害は署名と事業者台帳を照合してからforward fix。service_roleを一般顧客へ渡さない。
