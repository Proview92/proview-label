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
  // One business at a time: the Proview master works in the business that is open (or none, on All sites).
  // Every database request names it in the x-pl-org header, and the server only lets the master read and
  // change that business (plus the All sites list). Business logins don't need it.
  let scope = { master: false, org: null };
  const scopedFetch = (url, init) => {
    if (!scope.org || !/\/rest\/v1\//.test(String(url))) return fetch(url, init);
    const h = new Headers((init && init.headers) || {}); h.set('x-pl-org', scope.org);
    return fetch(url, { ...(init || {}), headers: h });
  };
  if (enabled) {
    sb = g.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storageKey: C.STORAGE_KEY || 'pv-label-auth' },
      global: { fetch: scopedFetch }
    });
  }
  const friendly = (e) => {
    const t = String((e && e.message) || e || '');
    if (/invalid login credentials/i.test(t)) return 'That email or password isn’t right. Try again, or use “Forgot password?”.';
    if (/email not confirmed/i.test(t)) return 'Confirm your email first: open the link we emailed you.';
    if (/already registered/i.test(t)) return 'There’s already an account for this email. Sign in instead.';
    if (/rate limit|too many/i.test(t)) return 'Too many attempts. Please wait a minute and try again.';
    if (/^TRIAL_USED: |^ALREADY_MEMBER: /.test(t)) return t.replace(/^[A-Z_]+: /, '');
    if (/failed to fetch|network/i.test(t)) return 'Can’t reach the server. Check your internet connection and try again.';
    return t || 'Something went wrong. Please try again.';
  };

  const LICENCE_URL = 'https://license.proviewcrm.co.uk';   // licence portal: master-only links (dashboard All sites / Add business)
  const SUPPORT = { phone: '020 8935 5495', email: 'info@proviewtechgroup.co.uk' };
  // Licence state of a business from whoami: 'suspended', 'nolicence' (never licensed: every new business starts
  // like this, migration 007), 'expired' (trial ended), 'trial' (a trial end date, set by hand) or 'active'
  const orgState = (o) => {
    if (!o) return 'active';
    if (o.suspended) return 'suspended';
    if (o.licensed === false || o.no_licence) return 'nolicence';
    if (o.trial_ends_at && (o.trial_expired || new Date(o.trial_ends_at) < new Date())) return 'expired';
    if (o.trial_ends_at) return 'trial';
    return 'active';
  };
  const lockMsg = (o) => {
    const st = orgState(o), n = (o && o.name) || 'This business';
    if (st === 'nolicence') return { title: 'No licence yet', text: 'No licence yet: buy a licence to start using Proview Label at ' + n + '. Nothing can be changed or synced until it has one.' };
    if (st === 'expired') return { title: 'Trial ended', text: n + '’s trial has ended. Your data is safe, but nothing can be changed or synced until you buy a licence.' };
    if (st === 'suspended') return { title: 'Account suspended', text: n + ' is suspended. Your data is safe, but nothing can be changed or synced until the licence is renewed.' };
    return null;
  };

  const Cloud = {
    enabled, friendly, url: C.SUPABASE_URL, key: C.SUPABASE_KEY, LICENCE_URL, SUPPORT, orgState, lockMsg,
    client: () => sb,
    async session() { if (!sb) return null; const { data } = await sb.auth.getSession(); return data.session; },
    async user() { const s = await Cloud.session(); return s ? s.user : null; },
    // True only when the sign-in has really been ended by the server (the saved login was thrown away).
    // A dropped connection never counts: supabase-js keeps the saved login when a refresh fails for network reasons.
    loginGone() {
      if (typeof navigator !== 'undefined' && navigator.onLine === false) return false;
      try { return !localStorage.getItem(C.STORAGE_KEY || 'pv-label-auth'); } catch (e) { return false; }
    },
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
    setScope(master, org) { scope = { master: !!master, org: (master && org) || null }; },
    scopeOrg: () => scope.org,
    async sync(P, opts) { return P.sync({ url: C.SUPABASE_URL, key: C.SUPABASE_KEY, token: await Cloud.token(), full: !!(opts && opts.full), scoped: scope.master, org: scope.org }); },
    // Re-read this person's access and purge cached data for businesses they no longer belong to.
    // Returns the whoami result (or null if it couldn't be checked; then nothing is purged).
    async prune(P) { let w; try { w = await Cloud.whoami(); } catch (e) { return null; } if (!w) return null; P.prune((w.orgs || []).map((o) => o.id)); return w; },
    // ----- businesses & back-office logins -----
    async createOrg(name, ownerEmail, ownerName) { const { data, error } = await sb.rpc('pl_create_org', { p_name: name, p_owner_email: ownerEmail || null, p_owner_name: ownerName || '' }); if (error) throw error; return data; },
    // master: business + location + Owner / Admin login in one go (migration 006). Returns { org_id, site_id, user_id, email, existing }.
    async addBusiness(business, name, email, mobile, password) { const { data, error } = await sb.rpc('pl_add_business', { p_business: business, p_name: name, p_email: email, p_mobile: mobile || '', p_password: password }); if (error) throw error; return data; },
    // Self sign-up, "Set up your business" (migrations 003/007): the business starts with no licence. Returns { org_id, site_id }.
    // trialReady(who): the server has the set-up feature (whoami then reports trial_used, now always false).
    trialReady(who) { return !!who && Object.prototype.hasOwnProperty.call(who, 'trial_used'); },
    async startTrial(business, site) { const { data, error } = await sb.rpc('pl_start_trial', { p_business: business, p_site: site || null }); if (error) throw error; return data; },
    // master: set (ISO date) or clear (null) a business's trial end; either way the business is licensed
    async setTrial(orgId, endsAt) { const { error } = await sb.rpc('pl_set_trial', { p_org: orgId, p_ends: endsAt || null }); if (error) throw error; },
    // master: give (licensed, optionally ending on endsAt) or remove (no licence) a business's licence (migration 007)
    async setLicence(orgId, licensed, endsAt) {
      const { error } = await sb.rpc('pl_set_licence', { p_org: orgId, p_licensed: !!licensed, p_ends: endsAt || null });
      if (error && licensed && (error.code === 'PGRST202' || /could not find the function/i.test(error.message || ''))) return Cloud.setTrial(orgId, endsAt);   // server before 007
      if (error) throw error;
    },
    // master: a LOCATION's licence (migration 009): type m1..m36 | lifetime | custom (endsAt) | trial (endsAt) | null = remove
    async setSiteLicence(siteId, type, endsAt, extend) {
      const { data, error } = await sb.rpc('pl_set_site_licence', { p_site: siteId, p_type: type || null, p_expires: endsAt || null, p_extend: !!extend });
      if (error) throw error; return data;
    },
    // the prices the licence portal sent (hub_plans): { m12: { label, amount, currency, link, ref, kind, plan }, ... }
    async plans() {
      const { data, error } = await sb.rpc('pl_plans');
      if (error) { if (error.code === 'PGRST202' || /could not find the function/i.test(error.message || '')) return {}; throw error; }   // server before 009
      return data || {};
    },
    async renameOrg(id, name) { const { error } = await sb.from('pl_orgs').update({ name }).eq('id', id); if (error) throw error; },
    async saveOrgSettings(id, settings) { const { error } = await sb.from('pl_orgs').update({ settings }).eq('id', id); if (error) throw error; },
    async members(orgIds) { let q = sb.from('pl_members').select('*').order('name'); if (orgIds) q = q.in('org_id', orgIds); const { data, error } = await q; if (error) throw error; return data || []; },
    async saveMember(m) {
      const row = { org_id: m.org_id, email: String(m.email || '').trim().toLowerCase(), name: m.name || '', role: m.role, site_ids: m.site_ids || [], features: m.role === 'manager' ? (m.features || {}) : {} };
      const q = (m.id ? sb.from('pl_members').update(row).eq('id', m.id) : sb.from('pl_members').insert(row)).select('id').single();
      const { data, error } = await q; if (error) throw new Error(/duplicate/i.test(error.message) ? 'That email already has a login for this business.' : error.message);
      return data && data.id;
    },
    // owner/admin (or master) sets someone's password, so they can sign in straight away with no email
    async setMemberPassword(memberId, password) {
      const t = await Cloud.token(); if (!t) throw new Error('Please sign in again.');
      const r = await fetch(C.SUPABASE_URL + '/functions/v1/pl-set-password', { method: 'POST',
        headers: { Authorization: 'Bearer ' + t, apikey: C.SUPABASE_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ member_id: memberId, password }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || j.error) throw new Error(j.error || ('Could not set the password (' + r.status + ')'));
      return j;
    },
    // ----- handheld pairing (migration 005) -----
    // handheld, not signed in: get (or keep) the pairing code for this handheld's secret
    async pairStart(secret) { const { data, error } = await sb.rpc('pl_pair_start', { p_secret: secret }); if (error) throw error; return data; },
    // handheld: { status: 'waiting' | 'expired' | 'paired', ... } (paired brings the handheld's own login)
    async pairPoll(secret) {
      const r = await fetch(C.SUPABASE_URL + '/functions/v1/pl-device-pair', { method: 'POST', headers: { 'content-type': 'application/json', apikey: C.SUPABASE_KEY }, body: JSON.stringify({ secret }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok || j.error) throw new Error(j.error || ('Pairing check failed (' + r.status + ')'));
      return j;
    },
    // back-office: pair the handheld showing this code
    async claimPair(code, siteId, name, mode) { const { data, error } = await sb.rpc('pl_pair_claim', { p_code: code, p_site: siteId, p_name: name, p_mode: mode }); if (error) throw error; return data; },
    async devices(orgIds) { let q = sb.from('pl_devices').select('*').order('name'); if (orgIds) q = q.in('org_id', orgIds); const { data, error } = await q; if (error) throw error; return data || []; },
    async updateDevice(id, name, siteId, mode) { const { error } = await sb.rpc('pl_device_update', { p_id: id, p_name: name, p_site: siteId, p_mode: mode }); if (error) throw error; },
    async removeDevice(id) { const { error } = await sb.rpc('pl_device_remove', { p_id: id }); if (error) throw error; },
    async removeMember(id) { const { error } = await sb.from('pl_members').delete().eq('id', id); if (error) throw error; }
  };
  g.PVLCloud = Cloud;
})(typeof window !== 'undefined' ? window : globalThis);
