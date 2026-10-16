import {normalizePostMetrics, normalizeAccountMetrics, importedPost} from '../domain/threads.ts';
export type ThreadsConfig = {accountId: string; accessToken: string; apiVersion: string};
/** Fixed host/path construction. Never follow an API-provided next URL or accept a user URL. */
export class ThreadsClient {
  private config: ThreadsConfig;
  private fetcher: typeof fetch;
  constructor(config: ThreadsConfig, fetcher: typeof fetch = fetch) {
    if (
      !/^\d{1,80}$/.test(config.accountId) ||
      !/^v\d+\.\d+$/.test(config.apiVersion) ||
      !config.accessToken ||
      /REPLACE/.test(config.accessToken)
    )
      throw new Error('THREADS_NOT_CONFIGURED');
    this.config = config;
    this.fetcher = fetcher;
  }
  private async request(
    path: string,
    params: Record<string, string>,
    method: 'GET' | 'POST' = 'GET',
  ): Promise<unknown> {
    const url = new URL(`https://graph.threads.net/${this.config.apiVersion}/${path}`);
    const headers: Record<string, string> = {Authorization: `Bearer ${this.config.accessToken}`};
    let body: string | undefined;
    if (method === 'GET') for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    else {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      body = new URLSearchParams(params).toString();
    }
    let response: Response;
    try {
      response = await this.fetcher(url, {
        method,
        headers,
        body,
        signal: AbortSignal.timeout(10000),
        redirect: 'error',
        cache: 'no-store',
      });
    } catch {
      throw new Error('THREADS_NETWORK_ERROR');
    }
    if (!response.ok)
      throw new Error(
        response.status === 429
          ? 'THREADS_RATE_LIMITED'
          : response.status === 401 || response.status === 403
            ? 'THREADS_PERMISSION_DENIED'
            : 'THREADS_API_ERROR',
      );
    try {
      return await response.json();
    } catch {
      throw new Error('THREADS_RESPONSE_SHAPE');
    }
  }
  async postMetrics(postId: string) {
    if (!/^\d{1,80}$/.test(postId)) throw new Error('INVALID_POST_ID');
    return normalizePostMetrics(
      await this.request(`${postId}/insights`, {metric: 'views,likes,replies,reposts,quotes,shares'}),
    );
  }
  async accountMetrics(since: Date, until: Date) {
    // followers_count must be requested without since/until.
    const followers = await this.request(`${this.config.accountId}/threads_insights`, {
      metric: 'followers_count',
    });
    const period = await this.request(`${this.config.accountId}/threads_insights`, {
      metric: 'views,likes,replies,reposts,quotes',
      since: String(Math.floor(+since / 1000)),
      until: String(Math.floor(+until / 1000)),
    });
    return [
      ...normalizeAccountMetrics(followers, since, until),
      ...normalizeAccountMetrics(period, since, until),
    ];
  }
  async listPosts(after?: string) {
    if (after && after.length > 2048) throw new Error('INVALID_CURSOR');
    const payload = (await this.request(`${this.config.accountId}/threads`, {
      fields: 'id,text,timestamp,is_reply',
      limit: '50',
      ...(after ? {after} : {}),
    })) as {data?: unknown[]; paging?: {cursors?: {after?: string}; next?: string}};
    if (!payload || !Array.isArray(payload.data)) throw new Error('THREADS_RESPONSE_SHAPE');
    const posts = payload.data.map(importedPost).filter((p): p is NonNullable<typeof p> => p !== null);
    const next = payload.paging?.next ? payload.paging?.cursors?.after : undefined;
    return {
      posts,
      skipped: payload.data.length - posts.length,
      nextCursor: typeof next === 'string' && next.length <= 2048 ? next : null,
    };
  }
  async createTextContainer(text: string) {
    if ([...text].length < 1 || [...text].length > 500) throw new Error('INVALID_POST_LENGTH');
    const data = (await this.request(
      `${this.config.accountId}/threads`,
      {media_type: 'TEXT', text},
      'POST',
    )) as {id?: string};
    if (!data || typeof data.id !== 'string' || !/^\d{1,80}$/.test(data.id))
      throw new Error('THREADS_RESPONSE_SHAPE');
    return data.id;
  }
  async publishContainer(containerId: string) {
    if (!/^\d{1,80}$/.test(containerId)) throw new Error('INVALID_CONTAINER_ID');
    // NO automatic POST retry. A lost response may still mean a published post.
    const data = (await this.request(
      `${this.config.accountId}/threads_publish`,
      {creation_id: containerId},
      'POST',
    )) as {id?: string};
    if (!data || typeof data.id !== 'string' || !/^\d{1,80}$/.test(data.id))
      throw new Error('THREADS_RESPONSE_SHAPE');
    return data.id;
  }
}
