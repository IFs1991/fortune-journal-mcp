# Sources / provenance / assumptions

Checked for implementation design on 2026-10-14. Retrieved documentation can lag the live provider; verify again in staging. Source links are technical references, not proof of a successful deployment.

## Primary technical references

- Meta Threads Insights: https://developers.facebook.com/docs/threads/insights
  Media metrics views/likes/replies/reposts/quotes/shares; account followers_count does not accept since/until; account views is profile views; daily series and total_value have different shapes. Metrics may be missing. No historical point-in-time snapshot API is assumed.
- Supabase RLS: https://supabase.com/docs/guides/database/postgres/row-level-security
  RLS on exposed tables, explicit roles/policies, service_role bypass. Column grants are separate.
- Supabase MCP OAuth: https://supabase.com/docs/guides/auth/oauth-server/mcp-authentication
  OAuth connection / consent requires real-host testing.
- Supabase changelog: https://supabase.com/changelog
  HTML checked; markdown fetch unavailable. Data API exposure / explicit grants and runtime changes must be checked against actual project configuration.
- Vercel MCP: https://vercel.com/docs/mcp/deploy-mcp-servers-to-vercel
  Endpoint adapter and auth examples. Inherited exact SDK/package versions have NOT been installed/peer-verified here.
- Supabase CLI: https://supabase.com/docs/reference/cli/introduction
  Use real `migration new` and reviewed history. No synthetic timestamps are supplied for added stages.

## User-provided business proposal

Co–Star / CHANI / The Pattern / Astrotalk / LINE占いの5事例から導いた追加提案が設計入力。各社の内部DBは非公開、各機能が転換率を上げた因果効果は示されていない。本パッケージは価格・売上成長・サービス終了日を再検証した市場調査報告ではない。これらを確定事実としてコードやKPIの目標に埋め込んでいない。

採用した仮説は「日常的接触→初回価値→再訪→支払いを観測する」「投稿を実験属性で追う」「AI運用を失敗/費用と共に残す」。その有効性は実顧客データで検証する。

## Explicit product assumptions

Free/Trial/Premiumの限度、14日Trial、価格候補$4.99、90/400日保持、hourly cron・2h計測窓、1日2投稿は設計仮説。法律・ホスト規約・Meta権限・支払事業者の承認・顧客同意を代替しない。

## Verified versions (2026-10-15)

Checked against the npm registry and the installed packages' own type declarations/READMEs (not memory):
next 15.5.27, react/react-dom 19.2.3, @modelcontextprotocol/server 2.3.1, mcp-handler 2.3.0 (MCP 2026-07-28 native + 2025 stateless fallback), @supabase/supabase-js 2.117.3 (auth `oauth.getAuthorizationDetails/approveAuthorization/denyAuthorization/listGrants/revokeGrant`), @supabase/ssr 0.12.7, zod 4.2.1, typescript 5.8.3, Supabase CLI 2.120.0, local GoTrue v2.197.0 OAuth 2.1 server (AS metadata at `/auth/v1/.well-known/oauth-authorization-server`, S256 PKCE, DCR, no RFC 7009 revocation endpoint advertised). Hosted Supabase/Vercel behaviour still needs Staging confirmation.
