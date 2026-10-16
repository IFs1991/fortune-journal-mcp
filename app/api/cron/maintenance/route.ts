import {secureEqual} from '@/src/domain/security';
import {secret} from '@/src/lib/secrets';
import {maintenance} from '@/src/ops/maintenance';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

/** Vercel Cron (vercel.json). Emits one greppable FJ_MAINTENANCE_* line per run for log alerts; no payloads. */
export async function GET(request: Request) {
  let cronSecret: string;
  try {
    cronSecret = secret('CRON_SECRET');
  } catch {
    console.error(JSON.stringify({code: 'FJ_CRON_NOT_CONFIGURED'}));
    return Response.json({error: 'NOT_CONFIGURED'}, {status: 503});
  }
  if (!secureEqual(request.headers.get('authorization') ?? '', `Bearer ${cronSecret}`)) {
    return Response.json({error: 'UNAUTHORIZED'}, {status: 401});
  }
  try {
    const value = await maintenance();
    const failures = value.results.filter((step) => 'errorCode' in step || step.purged === false).length;
    const code = failures ? 'FJ_MAINTENANCE_PARTIAL_FAILURE' : 'FJ_MAINTENANCE_OK';
    console[failures ? 'error' : 'info'](JSON.stringify({code, failures}));
    return Response.json(value, {headers: {'Cache-Control': 'no-store'}});
  } catch (error) {
    const reason = error instanceof Error && /^[A-Z_]+$/.test(error.message) ? error.message : 'UNEXPECTED';
    console.error(JSON.stringify({code: 'FJ_MAINTENANCE_FAILED', reason}));
    return Response.json({error: 'MAINTENANCE_FAILED'}, {status: 503});
  }
}
