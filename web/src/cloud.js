/* Proview Label — cloud layer (shared by the back-office and the Android app).
 * Real accounts on the proview-label Supabase project + "Sign in with Proview account"
 * (dashboard.proviewcrm.co.uk hands over a signed, single-use token that sso-login swaps for a session).
 * Enabled only when window.PVL_CONFIG has SUPABASE_URL + SUPABASE_KEY; otherwise the apps run on demo data.
 */
(function (g) {
  'use strict';
  const C = g.PVL_CONFIG || {};
  const enabled = !!(C.SUPABASE_URL && C.SUPABASE_KEY && g.supabase && g.supabase.createClient);
  const PV_ACCOUNT = C.PV_ACCOUNT_URL || 'https://dashboard.proviewcrm.co.uk/';
  let sb = null;
  if (enabled) {
    sb = g.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storageKey: C.STORAGE_KEY || 'pv-label-auth' }
    });
  }
  const friendly = (e) => {
    const t = String((e && e.message) || e || '');
    if (/invalid login credentials/i.test(t)) return 'That email or password isn’t right. Try again, or use “Forgot password?”.';
    if (/email not confirmed/i.test(t)) return 'Confirm your email first: open the link we emailed you.';
    if (/already registered/i.test(t)) return 'There’s already an account for this email. Sign in instead.';
    if (/rate limit|too many/i.test(t)) return 'Too many attempts. Please wait a minute and try again.';
    if (/failed to fetch|network/i.test(t)) return 'Can’t reach the server. Check your internet connection and try again.';
    return t || 'Something went wrong. Please try again.';
  };

  const Cloud = {
    enabled, friendly, url: C.SUPABASE_URL, key: C.SUPABASE_KEY,
    client: () => sb,
    async session() { if (!sb) return null; const { data } = await sb.auth.getSession(); return data.session; },
    async user() { const s = await Cloud.session(); return s ? s.user : null; },
    async token() { const s = await Cloud.session(); return s ? s.access_token : null; },
    async signIn(email, password) { const { data, error } = await sb.auth.signInWithPassword({ email, password }); if (error) throw error; return data.user; },
    async signUp(email, password, redirect) { const { data, error } = await sb.auth.signUp({ email, password, options: { emailRedirectTo: redirect } }); if (error) throw error; return data; },
    async resetPassword(email, redirect) { const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: redirect }); if (error) throw error; },
    async setPassword(pw) { const { error } = await sb.auth.updateUser({ password: pw }); if (error) throw error; },
    async signOut() { if (sb) await sb.auth.signOut(); },
    onRecovery(fn) { if (sb) sb.auth.onAuthStateChange((ev) => { if (ev === 'PASSWORD_RECOVERY') fn(); }); },
    // Send the person to their Proview account to sign in; they come back with #pv_sso=<token>
    proviewAccountUrl(returnUrl) { return PV_ACCOUNT + '?app=label&return=' + encodeURIComponent(returnUrl); },
    // If we've just come back from the Proview account page, swap the hand-off for a session.
    async consumeSsoHash() {
      const m = (g.location.hash || '').match(/[#&]pv_sso=([^&]+)/);
      if (!m || !sb) return false;
      history.replaceState(null, '', g.location.pathname + g.location.search);
      const r = await fetch(C.SUPABASE_URL + '/functions/v1/sso-login', { method: 'POST', headers: { 'content-type': 'application/json', apikey: C.SUPABASE_KEY }, body: JSON.stringify({ assertion: decodeURIComponent(m[1]) }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || !j.token_hash) throw new Error(j.error || 'Sign-in with your Proview account failed. Please try again.');
      const cur = await Cloud.user();
      if (cur && String(cur.email || '').toLowerCase() !== j.email) await sb.auth.signOut();
      const v = await sb.auth.verifyOtp({ token_hash: j.token_hash, type: 'magiclink' });
      if (v.error) throw v.error;
      return true;
    },
    // { email, master, orgs: [{ id, name, role, site_ids, settings, suspended }] }
    async whoami() { const { data, error } = await sb.rpc('pl_whoami'); if (error) throw error; return data; },
    async sync(P) { return P.sync({ url: C.SUPABASE_URL, key: C.SUPABASE_KEY, token: await Cloud.token() }); },
    // ----- businesses & back-office logins -----
    async createOrg(name, ownerEmail, ownerName) { const { data, error } = await sb.rpc('pl_create_org', { p_name: name, p_owner_email: ownerEmail || null, p_owner_name: ownerName || '' }); if (error) throw error; return data; },
    async renameOrg(id, name) { const { error } = await sb.from('pl_orgs').update({ name }).eq('id', id); if (error) throw error; },
    async saveOrgSettings(id, settings) { const { error } = await sb.from('pl_orgs').update({ settings }).eq('id', id); if (error) throw error; },
    async members(orgIds) { let q = sb.from('pl_members').select('*').order('name'); if (orgIds) q = q.in('org_id', orgIds); const { data, error } = await q; if (error) throw error; return data || []; },
    async saveMember(m) {
      const row = { org_id: m.org_id, email: String(m.email || '').trim().toLowerCase(), name: m.name || '', role: m.role, site_ids: m.site_ids || [], features: m.role === 'manager' ? (m.features || {}) : {} };
      const q = m.id ? sb.from('pl_members').update(row).eq('id', m.id) : sb.from('pl_members').insert(row);
      const { error } = await q; if (error) throw new Error(/duplicate/i.test(error.message) ? 'That email already has a login for this business.' : error.message);
    },
    async removeMember(id) { const { error } = await sb.from('pl_members').delete().eq('id', id); if (error) throw error; }
  };
  g.PVLCloud = Cloud;
})(typeof window !== 'undefined' ? window : globalThis);
