import {redirect} from 'next/navigation';
import {serverSupabase} from '@/src/lib/supabase/server';

export default async function OAuthConsent({searchParams}:{searchParams:Promise<{authorization_id?:string}>}) {
  const authorizationId=(await searchParams).authorization_id;
  if(!authorizationId || authorizationId.length>256) return <main>Invalid authorization request.</main>;
  const supabase=await serverSupabase();
  const {data:{user}}=await supabase.auth.getUser();
  if(!user) redirect(`/login?next=${encodeURIComponent(`/oauth/consent?authorization_id=${encodeURIComponent(authorizationId)}`)}`);
  const {data:details,error}=await supabase.auth.oauth.getAuthorizationDetails(authorizationId);
  if(error || !details) return <main>Connection request expired or invalid.</main>;
  if(!('authorization_id' in details)) redirect(details.redirect_url);
  return <main className="stack">
    <h1>Connect Fortune Journal</h1>
    <p><strong>{details.client.name}</strong> requests permission to use your Fortune Journal account.</p>
    <div className="notice">
      <div>Client: {details.client.name}</div>
      <div>Requested permissions: {details.scope || 'Account connection only'}</div>
      <div>Callback: {details.redirect_uri}</div>
    </div>
    <p>This connector calculates fortunes and checks your account access. It does <strong>not</strong> access your Google Sheets. You can revoke this connection later.</p>
    <form method="POST" action="/api/oauth/decision" className="row">
      <input type="hidden" name="authorization_id" value={authorizationId}/>
      <button name="decision" value="approve">Allow connection</button>
      <button className="secondary" name="decision" value="deny">Deny</button>
    </form>
  </main>;
}
