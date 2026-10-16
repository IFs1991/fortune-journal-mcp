'use client';
import {useState} from 'react';
import {browserSupabase} from '@/src/lib/supabase/browser';
import {safeNextPath} from '@/src/lib/urls';

export default function GoogleButton({nextPath, referral}: {nextPath: string; referral?: string}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function login() {
    setBusy(true);
    setError('');
    const next = safeNextPath(nextPath);
    const {error: authError} = await browserSupabase().auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}${referral ? `&ref=${encodeURIComponent(referral)}` : ''}`,
      },
    });
    if (authError) {
      setError('Could not start Google sign-in.');
      setBusy(false);
    }
  }
  return (
    <div className="stack">
      <button onClick={login} disabled={busy}>
        {busy ? 'Connecting…' : 'Continue with Google'}
      </button>
      {error ? <p role="alert">{error}</p> : null}
    </div>
  );
}
