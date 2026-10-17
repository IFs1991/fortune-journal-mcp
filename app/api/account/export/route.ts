import {exportPage, parseExportRequest} from '@/src/account';
import {appOrigin} from '@/src/lib/env';
import {sameOriginNavigation} from '@/src/lib/urls';
import {webSession} from '@/src/lib/web-session';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(request: Request) {
  if (!sameOriginNavigation(request, appOrigin())) return Response.json({error: 'FORBIDDEN'}, {status: 403});
  const session = await webSession();
  if (!session) return Response.json({error: 'UNAUTHORIZED'}, {status: 401});
  const exportRequest = parseExportRequest(new URL(request.url).searchParams);
  if (exportRequest === 'invalid_resource') return Response.json({error: 'INVALID_RESOURCE'}, {status: 400});
  if (exportRequest === 'invalid_page') return Response.json({error: 'INVALID_PAGE'}, {status: 400});
  const page = await exportPage(session.user.id, exportRequest);
  if (!page) return Response.json({error: 'EXPORT_FAILED'}, {status: 503});
  const filename = `fortune-journal-${page.resource}-${exportRequest.offset}.json`;
  return Response.json(page, {
    headers: {'Cache-Control': 'no-store', 'Content-Disposition': `attachment; filename="${filename}"`},
  });
}
