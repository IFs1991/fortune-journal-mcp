import {readBoundedText, verifyOps} from '@/src/domain/security';
import {isEnabled} from '@/src/lib/env';
import {opsCommand, publicErrorCode, runCommand} from '@/src/ops/commands';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

const NO_STORE = {'Cache-Control': 'no-store'};

/** Operator API: HMAC over method/path/timestamp/body with its own key; never customer OAuth. */
export async function POST(request: Request) {
  if (!isEnabled('OPERATIONS_ENABLED')) return Response.json({error: 'OPERATIONS_DISABLED'}, {status: 503});
  const url = new URL(request.url);
  if (!request.headers.get('content-type')?.startsWith('application/json') || url.search) {
    return Response.json({error: 'INVALID_REQUEST'}, {status: 400});
  }
  let body: string;
  try {
    body = await readBoundedText(request);
  } catch {
    return Response.json({error: 'BODY_TOO_LARGE'}, {status: 413});
  }
  const signed = verifyOps(
    process.env.OPS_HMAC_KEY,
    'POST',
    url.pathname,
    request.headers.get('x-fj-timestamp'),
    request.headers.get('x-fj-signature'),
    body,
  );
  if (!signed) return Response.json({error: 'UNAUTHORIZED'}, {status: 401});

  const parsed = opsCommand.safeParse(parseJson(body));
  if (!parsed.success) return Response.json({error: 'INVALID_COMMAND'}, {status: 400});
  const command = parsed.data;

  try {
    return Response.json(await runCommand(command), {headers: NO_STORE});
  } catch (error) {
    const code = publicErrorCode(error);
    console.error(
      JSON.stringify({code: 'FJ_OPS_FAILED', requestId: command.requestId, action: command.action}),
    );
    return Response.json({error: code}, {status: code.endsWith('_DISABLED') ? 503 : 409, headers: NO_STORE});
  }
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
