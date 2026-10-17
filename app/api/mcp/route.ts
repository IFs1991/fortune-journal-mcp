import {createMcpHandler, withMcpAuth} from 'mcp-handler';
import {readBoundedText} from '@/src/domain/security';
import {appOrigin, mcpAllowedOrigins} from '@/src/lib/env';
import {verifyOAuthBearer} from '@/src/lib/oauth';
import {runWithRequestMetrics} from '@/src/lib/perf';
import {limitMcp} from '@/src/lib/rate-limit';
import {mcpRequestCheck} from '@/src/lib/urls';
import {registerTools, SERVER_INSTRUCTIONS} from '@/src/mcp/tools';

export const runtime = 'nodejs';
export const maxDuration = 30;
export const dynamic = 'force-dynamic';

/** Largest JSON-RPC body accepted; tool inputs are a few hundred bytes. */
const MAX_BODY_BYTES = 65_536;

const handler = createMcpHandler(registerTools, {instructions: SERVER_INSTRUCTIONS});

// resourceUrl is pinned to APP_ORIGIN (read per request: it is runtime configuration) so the
// WWW-Authenticate discovery challenge never trusts forwarded Host headers. Each request gets its own
// metrics context so FJ_MCP_TIMING attributes Auth/DB calls to the right tool call.
async function authenticated(request: Request): Promise<Response> {
  const origin = appOrigin();
  // Before authentication: a valid bearer never makes a foreign Origin or Host acceptable.
  const check = mcpRequestCheck(request, origin, mcpAllowedOrigins());
  if (check === 'forbidden_origin') return Response.json({error: 'FORBIDDEN_ORIGIN'}, {status: 403});
  if (check === 'misdirected_host') return Response.json({error: 'MISDIRECTED_REQUEST'}, {status: 421});
  const limited = limitMcp(request);
  if (limited) return limited;
  let bounded = request;
  if (request.method === 'POST') {
    try {
      const body = await readBoundedText(request, MAX_BODY_BYTES);
      const headers = new Headers(request.headers);
      headers.delete('content-length');
      headers.delete('transfer-encoding');
      bounded = new Request(request.url, {method: 'POST', headers, body});
    } catch {
      return Response.json({error: 'BODY_TOO_LARGE'}, {status: 413});
    }
  }
  const withAuth = withMcpAuth(handler, verifyOAuthBearer, {
    required: true,
    resourceMetadataPath: '/.well-known/oauth-protected-resource',
    resourceUrl: origin,
  });
  return runWithRequestMetrics(() => withAuth(bounded));
}

export {authenticated as GET, authenticated as POST};
