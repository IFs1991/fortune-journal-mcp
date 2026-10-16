import GoogleButton from './google-button';
import {loadPreferences} from '@/src/account';
import {readReferral} from '@/src/domain/security';
import {serverSupabase} from '@/src/lib/supabase/server';
import {safeNextPath} from '@/src/lib/urls';

export default async function Login({
  searchParams,
}: {
  searchParams: Promise<{next?: string; ref?: string; connections?: string}>;
}) {
  const params = await searchParams;
  const next = safeNextPath(params.next);
  const ref = readReferral(process.env.ATTRIBUTION_HMAC_KEY, params.ref) ? params.ref : undefined;
  const supabase = await serverSupabase();
  const {
    data: {user},
  } = await supabase.auth.getUser();
  // Independent reads: run them together. prefs === null means it could not be loaded (never inferred).
  const [prefs, grants] = user
    ? await Promise.all([loadPreferences(user.id), supabase.auth.oauth.listGrants()])
    : [null, null];
  return (
    <main className="stack">
      <div>
        <h1>Fortune Journal</h1>
        <p>Your everyday AI, with a small fortune journal of your own.</p>
      </div>
      {user ? (
        <>
          <div className="notice">Signed in with Google{user.email ? ` as ${user.email}` : ''}.</div>
          {next !== '/login' ? <a href={next}>Continue to connector approval</a> : null}
          <p>
            Your reading text, birth information and life journal stay in your Google account. We retain
            minimal account, billing and 90-day per-request metadata to operate the service; the first-use
            timestamp remains with your account.
          </p>
          <details>
            <summary>Optional data preferences</summary>
            <p>
              Core calculations work without optional analytics. Theme tracking is a separate choice.
              Withdrawal deletes optional events and ratings and clears saved topics; operational quota
              metadata remains for up to 90 days.
            </p>
            {user && !prefs ? (
              <p>Preferences could not be loaded. Please retry; no choice has been inferred.</p>
            ) : (
              <form method="POST" action="/api/account/preferences" className="stack">
                {ref ? <input type="hidden" name="ref" value={ref} /> : null}
                <label>
                  <input type="checkbox" name="analytics" value="yes" defaultChecked={!!prefs?.analytics} />{' '}
                  Share optional usage events and explicit fixed-label feedback
                </label>
                <label>
                  <input type="checkbox" name="interests" value="yes" defaultChecked={!!prefs?.interests} />{' '}
                  Also store the themes I explicitly choose (love, work, money, general)
                </label>
                <label>
                  Where did you discover this service? Optional.
                  <select name="source" defaultValue="unknown">
                    <option value="unknown">Prefer not to say / unknown</option>
                    <option value="threads">Threads</option>
                    <option value="chatgpt">ChatGPT</option>
                    <option value="claude">Claude</option>
                    <option value="direct">Website / direct</option>
                  </select>
                </label>
                <button type="submit">Save preferences</button>
              </form>
            )}
          </details>
          <details open={params.connections === 'revoked'}>
            <summary>Connected AI apps</summary>
            {params.connections === 'revoked' ? (
              <p role="status">
                Connection revoked. That app can no longer use your Fortune Journal account.
              </p>
            ) : null}
            {grants?.error ? (
              <p>Connected apps could not be loaded. Please retry.</p>
            ) : !grants?.data?.length ? (
              <p>No AI apps are connected.</p>
            ) : (
              <ul className="stack">
                {grants.data.map((g) => (
                  <li key={g.client.id}>
                    <strong>{g.client.name}</strong>{' '}
                    <small>connected {new Date(g.granted_at).toISOString().slice(0, 10)}</small>
                    <form method="post" action="/api/oauth/revoke">
                      <input type="hidden" name="client_id" value={g.client.id} />
                      <button className="secondary">Revoke</button>
                    </form>
                  </li>
                ))}
              </ul>
            )}
          </details>
          <details>
            <summary>Export service data</summary>
            <p>
              Exports are paginated (100 records per page). Follow nextOffset with the same asOf until hasMore
              is false. This does not export or modify your Google Sheets.
            </p>
            <a href="/api/account/export">Download export index and account page</a>
          </details>
          <form method="post" action="/auth/signout">
            <button className="secondary">Sign out</button>
          </form>
          <details>
            <summary>Delete account</summary>
            <p>
              Cancel billing agreements first. Your Google Sheets are not deleted. Minimal legally required
              payment references may remain at the payment processor and in the service ledger.
            </p>
            <form method="post" action="/api/account/delete" className="stack">
              <label>
                Type DELETE_MY_ACCOUNT
                <input name="confirmation" required pattern="DELETE_MY_ACCOUNT" autoComplete="off" />
              </label>
              <button className="danger">Delete account permanently</button>
            </form>
          </details>
        </>
      ) : (
        <>
          <GoogleButton nextPath={next} referral={ref} />
          <small>Google sign-in only. We do not request Drive or Sheets permissions.</small>
        </>
      )}
      <small>
        For entertainment and reflection, not factual predictions. Optional collection is never enabled by
        signing in.
      </small>
    </main>
  );
}
