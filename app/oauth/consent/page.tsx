import {redirect} from 'next/navigation';
import {clientPlatform} from '@/src/lib/env';
import {webSession} from '@/src/lib/web-session';

export default async function OAuthConsent({
  searchParams,
}: {
  searchParams: Promise<{authorization_id?: string}>;
}) {
  const authorizationId = (await searchParams).authorization_id;
  if (!authorizationId || !/^[A-Za-z0-9_-]{5,256}$/.test(authorizationId))
    return <main>Invalid authorization request.</main>;
  const session = await webSession();
  if (!session)
    redirect(
      `/login?next=${encodeURIComponent(`/oauth/consent?authorization_id=${encodeURIComponent(authorizationId)}`)}`,
    );
  const {data: details, error} = await session.supabase.auth.oauth.getAuthorizationDetails(authorizationId);
  if (error || !details) return <main>Connection request expired or invalid.</main>;
  if (!('authorization_id' in details)) redirect(details.redirect_url);
  // Dynamically registered clients choose their own name; only operator-listed client IDs are shown as verified.
  const verified = clientPlatform(details.client.id) !== 'unknown';
  let callbackHost = details.redirect_uri;
  try {
    callbackHost = new URL(details.redirect_uri).host;
  } catch {
    /* show the raw value */
  }
  return (
    <main className="stack">
      <h1>Connect Fortune Journal</h1>
      <p>
        <strong>{details.client.name}</strong> requests permission to use your Fortune Journal account.
      </p>
      <div className="notice">
        <div>
          Client: {details.client.name}{' '}
          {verified ? (
            <small>(verified)</small>
          ) : (
            <small>(unverified — this name is chosen by the app itself)</small>
          )}
        </div>
        <div>
          Sends you back to: <strong>{callbackHost}</strong>
        </div>
        <div>Requested permissions: {details.scope || 'Account connection only'}</div>
        <div>Callback: {details.redirect_uri}</div>
      </div>
      {verified ? null : (
        <p role="note">
          Only allow this if you started connecting Fortune Journal from your AI app just now and recognise
          the site above.
        </p>
      )}
      <p>
        This connector calculates fortunes and checks your account access. It does <strong>not</strong> access
        your Google Sheets. You can revoke this connection at any time under <em>Connected AI apps</em> on
        your account page.
      </p>
      <form method="POST" action="/api/oauth/decision" className="row">
        <input type="hidden" name="authorization_id" value={authorizationId} />
        <button name="decision" value="approve">
          Allow connection
        </button>
        <button className="secondary" name="decision" value="deny">
          Deny
        </button>
      </form>
    </main>
  );
}
