import {createMcpHandler, withMcpAuth} from 'mcp-handler';
import {appOrigin} from '@/src/lib/env';
import {verifyOAuthBearer} from '@/src/lib/oauth';
import {runWithRequestMetrics} from '@/src/lib/perf';
import {registerTools, SERVER_INSTRUCTIONS} from '@/src/mcp/tools';

export const runtime = 'nodejs';
export const maxDuration = 30;
export const dynamic = 'force-dynamic';

const handler = createMcpHandler(registerTools, {instructions: SERVER_INSTRUCTIONS});

// resourceUrl is pinned to APP_ORIGIN (read per request: it is runtime configuration) so the
// WWW-Authenticate discovery challenge never trusts forwarded Host headers. Each request gets its own
// metrics context so FJ_MCP_TIMING attributes Auth/DB calls to the right tool call.
function authenticated(request: Request): Promise<Response> {
  const withAuth = withMcpAuth(handler, verifyOAuthBearer, {
    required: true,
    resourceMetadataPath: '/.well-known/oauth-protected-resource',
    resourceUrl: appOrigin(),
  });
  return runWithRequestMetrics(() => withAuth(request));
}

export {authenticated as GET, authenticated as POST};
