// Headless tests of the Label back-office (web/site/index.html, live build) against a mocked Supabase:
// master direct, master opened from the licence portal (biz), reload, switch, old link, owner / manager unchanged.
const puppeteer = require('/opt/npm-tools/node_modules/puppeteer-core');
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = process.argv[2], PORT = 8131, SHOTS = process.argv[3] || require('os').tmpdir();
const srv = http.createServer((q, r) => { const f = path.join(ROOT, decodeURIComponent(q.url.split('?')[0]).replace(/^\/$/, '/index.html')); fs.readFile(f, (e, b) => { if (e) { r.writeHead(200, { 'content-type': 'text/html' }); return r.end('<p>blank</p>'); } r.writeHead(200, { 'content-type': 'text/html' }); r.end(b); }); });
const UID = '3340d285-2ca8-4b98-890b-a237c9867296';
const fakeJwt = (em) => { const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url'); return b({ alg: 'HS256', typ: 'JWT' }) + '.' + b({ sub: UID, role: 'authenticated', email: em, exp: 4102444800 }) + '.sig'; };
const user = (em) => ({ id: UID, email: em, aud: 'authenticated', role: 'authenticated', email_confirmed_at: '2026-11-08T00:00:00Z' });
const session = (em) => ({ access_token: fakeJwt(em), refresh_token: 'r', token_type: 'bearer', expires_in: 3600, expires_at: 4102444800, user: user(em) });
const results = []; const ok = (n, c, x) => results.push((c ? 'PASS ' : 'FAIL ') + n + (x && !c ? ' :: ' + x : ''));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MASTER = 'altun@proviewtech.co.uk';
const org = (id, name, role, extra = {}) => ({ id, name, settings: {}, suspended: false, role, site_ids: [], member_id: role === 'master' ? null : 'm-' + id, features: {}, trial_ends_at: null, trial_expired: false, licensed: true, no_licence: false, locked: false,
  sites: [], ...extra });
const ORGS = { org_a: 'Burger Barn', org_b: 'Pizza Palace' };
const SITES = [['site_a1', 'org_a', 'Camden Kitchen'], ['site_a2', 'org_a', 'Soho Kitchen'], ['site_b1', 'org_b', 'Leeds Pizzeria']];
const rec = (id, kind, orgId, data) => ({ id, kind, org_id: orgId, data: { id, orgId, ...data }, deleted: false, updated_at: '2026-11-08T00:00:00Z' });
const RECORDS = [...SITES.map(([id, o, n]) => rec(id, 'sites', o, { name: n, address: n + ' road', region: '' })),
  rec('p_a', 'products', 'org_a', { name: 'Beef patty secret', categoryId: '', allergens: [] }), rec('p_b', 'products', 'org_b', { name: 'Margherita secret', categoryId: '', allergens: [] }),
  rec('d_b', 'devices', 'org_b', { name: 'Leeds handheld', siteId: 'site_b1' })];
const licOf = (o) => SITES.filter((s) => s[1] === o).map(([id]) => ({ id, licence_type: 'lifetime', licence_starts_at: null, licence_expires_at: null }));

async function run(browser, opts, body) {
  const st = { calls: [], sso: null };
  const page = opts.page || await browser.newPage(); const errs = [];
  if (!opts.page) {
    await page.setViewport({ width: 1366, height: 900 });
    page.on('pageerror', (e) => errs.push(e.message));
    await page.setRequestInterception(true);
    page.on('request', (rq) => {
      const u = rq.url(); if (!u.includes('supabase.co')) return rq.continue();
      const U = new URL(u), p = U.pathname, m = rq.method(), hOrg = rq.headers()['x-pl-org'] || '';
      if (m !== 'OPTIONS') st.calls.push(m + ' ' + p + U.search + ' [' + hOrg + ']');
      const res = (s, b) => rq.respond({ status: s, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }, body: JSON.stringify(b) });
      if (m === 'OPTIONS') return res(200, {});
      const O = page.__opts;
      if (p === '/functions/v1/sso-login') { st.sso = JSON.parse(rq.postData()); const r = O.ssoReply; return res(r.status || 200, r.body); }
      if (p === '/auth/v1/verify') return res(200, session(O.email));
      if (p === '/rest/v1/rpc/pl_whoami') {
        // the live server: the master gets every business; others their own
        // since migration 010 the master gets only the business named in x-pl-org (none without it)
        if (O.master) st.whoHdr = (st.whoHdr || []).concat(hOrg);
        const orgs = O.master ? Object.keys(ORGS).filter((id) => id === hOrg).map((id) => org(id, ORGS[id], 'master', { sites: licOf(id) }))
          : [org('org_a', 'Burger Barn', O.role, { site_ids: O.role === 'manager' ? ['site_a1'] : [], sites: licOf('org_a') })];
        return res(200, { email: O.email, master: !!O.master, trial_used: false, orgs });
      }
      if (p === '/rest/v1/pl_records' && m === 'GET') {
        // mimic RLS: master only in the business named by x-pl-org; others only org_a
        const want = (U.searchParams.get('org_id') || '').replace(/^eq\./, '');
        let rows = RECORDS.filter((r) => O.master ? (hOrg && r.org_id === hOrg) : r.org_id === 'org_a');
        if (want) rows = rows.filter((r) => r.org_id === want);
        const kin = U.searchParams.get('kind'); if (kin) { const ks = kin.replace(/^in\.\(|\)$/g, '').split(','); rows = rows.filter((r) => ks.includes(r.kind)); }
        if ((U.searchParams.get('select') || '') === 'id') return res(200, rows.map((r) => ({ id: r.id })));
        return res(200, rows);
      }
      if (p === '/rest/v1/pl_records') return res(201, []);
      if (p === '/rest/v1/pl_devices' || p === '/rest/v1/pl_members') return res(200, []);
      if (p === '/rest/v1/rpc/pl_plans') return res(200, {});
      if (p.startsWith('/auth/v1/user')) return res(200, user(O.email));
      if (p.startsWith('/auth/v1/logout')) return res(204, {});
      return res(404, { message: 'unmocked ' + p });
    });
  }
  page.__opts = opts;
  if (!opts.page) {
    await page.goto(`http://127.0.0.1:${PORT}/blank`, { waitUntil: "domcontentloaded" });
    await page.evaluate((s) => { localStorage.clear(); sessionStorage.clear(); localStorage.setItem('pv-label-auth', JSON.stringify(s)); }, session(opts.email));
  }
  await page.goto(`http://127.0.0.1:${PORT}/index.html${opts.url || ''}`, { waitUntil: 'networkidle0' }); await sleep(opts.wait || 900);
  await body(page, st);
  ok(opts.name + ': no page errors', !errs.length, errs.join(' | '));
  return page;
}
const text = (p) => p.evaluate(() => document.body.innerText);
const html = (p) => p.evaluate(() => document.documentElement.outerHTML);
const store = (p) => p.evaluate(() => Object.keys(localStorage).map((k) => k + '=' + localStorage.getItem(k)).join('\n'));
const recordCalls = (st) => st.calls.filter((c) => c.includes('/rest/v1/pl_records'));

(async () => {
  await new Promise((r) => srv.listen(PORT, r));
  const browser = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: 'new', args: ['--no-sandbox'] });

  // 1. master, signed in directly (no business from the portal)
  let p = await run(browser, { name: 'master direct', email: MASTER, master: true, url: '#sites' }, async (p, st) => {
    const t = await text(p);
    ok('master direct: "Open a location from the licence portal" page', /Open a location from the licence portal/.test(t), t.slice(0, 400));
    ok('master direct: button to the licence portal', await p.$eval('#toPortal', (a) => a.href) === 'https://license.proviewcrm.co.uk/');
    ok('master direct: no business record requested', recordCalls(st).length === 0, recordCalls(st).join('\n'));
    const h = await html(p), s = await store(p);
    ok('master direct: no business name or data on the page', !/Burger Barn|Pizza Palace|Camden K|Leeds|Beef patty|Margherita/.test(h), (h.match(/.{80}(Burger Barn|Pizza Palace|Camden K|Leeds|Beef patty|Margherita).{80}/s)||[])[0]);
    ok('master direct: nothing of any business kept on the device', !/Burger Barn|Pizza Palace|Camden K|Leeds|Beef patty|Margherita/.test(s), s.slice(0, 300));
    ok('master direct: no Locations page / Add business', !/Add business|All locations \(|Businesses/.test(t));
    ok('master direct: menu pages greyed out', await p.$$eval('.side .nav a', (a) => a.length > 0 && a.every((x) => x.classList.contains('off'))));
    ok('master direct: no location dropdown', !(await p.$('#sitePick')));
    await p.screenshot({ path: SHOTS + '/master-direct.png' });
    await p.click('.side .nav a.off'); await sleep(150);
    ok('master direct: greyed page says open from the portal', /Open a location from the licence portal first/.test(await p.$eval('#toast', (e) => e.textContent)));
  });
  await p.close();

  // 2. master opened from the licence portal (Burger Barn, two locations)
  p = await run(browser, { name: 'master biz', email: MASTER, master: true, url: '?open=org_b#pv_sso=TOKEN1', ssoReply: { body: { token_hash: 'h1', email: MASTER, open: 'org_a' } } }, async (p, st) => {
    ok('master biz: hand-off sent to sso-login', st.sso && st.sso.assertion === 'TOKEN1');
    ok('master biz: address cleaned (no open=, no pv_sso)', !/open=|pv_sso/.test(p.url()), p.url());
    const t = await text(p);
    ok('master biz: banner "Viewing Burger Barn as Proview"', /Viewing Burger Barn as Proview/.test(t), t.slice(0, 300));
    ok('master biz: Back to licence portal link', await p.$eval('.master-bar a', (a) => a.textContent.trim() === 'Back to licence portal' && a.href === 'https://license.proviewcrm.co.uk/'));
    ok('master biz: dashboard of the business', /Your locations/.test(t) && /Camden Kitchen/.test(t) && /Soho Kitchen/.test(t));
    const opts = await p.$$eval('#sitePick option', (o) => o.map((x) => x.textContent));
    ok('master biz: dropdown = the business\'s locations as the owner sees them', JSON.stringify(opts) === JSON.stringify(['All my locations (2)', 'Camden Kitchen', 'Soho Kitchen']), JSON.stringify(opts));
    const rc = recordCalls(st);
    ok('master biz: every record request names Burger Barn only', rc.length > 0 && rc.every((c) => c.includes('org_id=eq.org_a') && c.endsWith('[org_a]')), rc.join('\n'));
    ok('master biz: whoami sent x-pl-org org_a (migration 010)', (st.whoHdr || []).length > 0 && st.whoHdr.every((h) => h === 'org_a'), JSON.stringify(st.whoHdr));
    ok('master biz: the address\'s open=org_b was ignored', !st.calls.some((c) => c.includes('org_b')));
    const h = await html(p), s = await store(p);
    ok('master biz: no other business on the page or device', !/Pizza Palace|Leeds|Margherita/.test(h) && !/Pizza Palace|Leeds|Margherita/.test(s));
    ok('master biz: no Locations menu item / Add business', !(await p.$('.side .nav a[href="#sites"]')) && !/Add business/.test(t));
    await p.screenshot({ path: SHOTS + '/master-biz.png' });
    await p.evaluate(() => { location.hash = 'products'; }); await sleep(400);
    ok('master biz: Products works for the business', /Beef patty secret/.test(await text(p)) && !/Margherita/.test(await text(p)));
    await p.evaluate(() => { location.hash = 'devices'; }); await sleep(400);
    const d = await text(p);
    ok('master biz: Locations & devices with Licence… (master tool kept)', /Locations & devices/.test(d) && (await p.$$('[data-licf]')).length === 2);
    ok('master biz: Business card says locations are added and linked in the portal', /New locations are added, linked and unlinked in the licence portal/.test(d));
    ok('master biz: no "+ Add location" inside the business', !/Add location/.test(d) && !(await p.$('#addS')));
    await p.click('[data-licf]'); await sleep(200);
    ok('master biz: Licence… pop-up has the trial tool', /Trial \(set by hand\)/.test(await p.$eval('#modal', (e) => e.innerText)));
    await p.keyboard.press('Escape'); await p.evaluate(() => { const x = document.querySelector('#modal [data-x]'); if (x) x.click(); });
    await p.evaluate(() => { location.hash = 'sites'; }); await sleep(300);
    ok('master biz: #sites (old Locations page) goes to the Dashboard', /Your locations/.test(await text(p)) && !/Businesses/.test(await text(p)));
    // reload keeps the same business
    st.calls.length = 0; await p.reload({ waitUntil: 'networkidle0' }); await sleep(900);
    const t2 = await text(p);
    ok('master biz: reload stays in Burger Barn', /Viewing Burger Barn as Proview/.test(t2) && recordCalls(st).every((c) => c.endsWith('[org_a]')) && !/Pizza Palace/.test(await html(p)), t2.slice(0, 200));
  });
  // 3. same tab: the portal opens another location (Pizza Palace)
  await run(browser, { name: 'master switch', page: p, email: MASTER, master: true, url: '#pv_sso=TOKEN2', ssoReply: { body: { token_hash: 'h2', email: MASTER, open: 'org_b' } } }, async (p, st) => {
    const t = await text(p), h = await html(p);
    ok('master switch: now inside Pizza Palace', /Viewing Pizza Palace as Proview/.test(t) && /Leeds Pizzeria/.test(t), t.slice(0, 200));
    ok('master switch: Burger Barn no longer on the page', !/Burger Barn|Camden|Beef patty/.test(h));
    ok('master switch: one location = disabled box with its name', await p.$eval('#sitePick', (s) => s.disabled && s.textContent.trim() === 'Leeds Pizzeria'));
  });
  // 4. old link / dashboard: an SSO hand-off with no business -> the portal page again
  await run(browser, { name: 'master old link', page: p, email: MASTER, master: true, url: '#pv_sso=TOKEN3', ssoReply: { body: { token_hash: 'h3', email: MASTER } } }, async (p) => {
    const t = await text(p), h = await html(p);
    ok('master old link: "Open a location from the licence portal"', /Open a location from the licence portal/.test(t));
    ok('master old link: no business shown', !/Burger Barn|Pizza Palace|Leeds|Camden/.test(h));
  });
  // 5. a business that is not the master's (sso-login said open, but whoami doesn't have it): portal page, nothing loaded
  await run(browser, { name: 'master unknown biz', page: p, email: MASTER, master: true, url: '#pv_sso=TOKEN4', ssoReply: { body: { token_hash: 'h4', email: MASTER, open: 'org_zzz' } } }, async (p, st) => {
    ok('master unknown biz: portal page', /Open a location from the licence portal/.test(await text(p)));
  });
  await p.close();

  // 6. owner: unchanged (no banner, own business, Users)
  p = await run(browser, { name: 'owner', email: 'owner@burgerbarn.test', role: 'owner', url: '#overview' }, async (p, st) => {
    const t = await text(p);
    ok('owner: dashboard of their business', /Your locations/.test(t) && /Camden Kitchen/.test(t));
    ok('owner: no master banner', !(await p.$('.master-bar')));
    const opts = await p.$$eval('#sitePick option', (o) => o.map((x) => x.textContent));
    ok('owner: dropdown "All my locations (2)" + sites', JSON.stringify(opts) === JSON.stringify(['All my locations (2)', 'Camden Kitchen', 'Soho Kitchen']), JSON.stringify(opts));
    ok('owner: full sync, no x-pl-org', recordCalls(st).length > 0 && recordCalls(st).every((c) => c.endsWith('[]')), recordCalls(st).join('\n'));
    ok('owner: menu has Settings, no Locations', !!(await p.$('.side .nav a[href="#settings"]')) && !(await p.$('.side .nav a[href="#sites"]')));
    await p.screenshot({ path: SHOTS + '/owner.png' });
    // LOCATIONS_LINK_SPEC: no adding locations; editing one stays
    await p.evaluate(() => { location.hash = 'devices'; }); await sleep(400);
    const dt = await text(p);
    ok('owner: Locations & devices has no "+ Add location"', /Locations & devices/.test(dt) && !/Add location/.test(dt) && !(await p.$('#addS')), dt.slice(0, 300));
    ok('owner: a location can still be edited', !!(await p.$('[data-es]')));
  });
  await p.close();
  // 7. owner arriving by SSO: a reply without open is normal; nothing changes
  p = await run(browser, { name: 'owner sso', email: 'owner@burgerbarn.test', role: 'owner', url: '#pv_sso=TOK', ssoReply: { body: { token_hash: 'h', email: 'owner@burgerbarn.test' } } }, async (p) => {
    ok('owner sso: signed in to their business', /Camden Kitchen/.test(await text(p)) && !(await p.$('.master-bar')));
  });
  await p.close();
  // 8. manager: unchanged (their one location, no Settings)
  p = await run(browser, { name: 'manager', email: 'mgr@burgerbarn.test', role: 'manager', url: '#overview' }, async (p) => {
    ok('manager: their location only (disabled box)', await p.$eval('#sitePick', (s) => s.disabled && s.textContent.trim() === 'Camden Kitchen'));
    ok('manager: no Settings, no banner', !(await p.$('.side .nav a[href="#settings"]')) && !(await p.$('.master-bar')));
  });
  await p.close();
  // 9. sso-login refuses (e.g. business gone): the message is shown on sign-in
  p = await run(browser, { name: 'sso refused', wait: 200, email: MASTER, master: true, url: '#pv_sso=BAD', ssoReply: { status: 404, body: { error: 'That business no longer exists in Proview Label. Refresh the licence portal and try again.' } } }, async (p) => {
    ok('sso refused: the reason is shown', /That business no longer exists in Proview Label/.test(await p.$eval('#toast', (e) => e.textContent)));
    ok('sso refused: no business opened', /Open a location from the licence portal/.test(await text(p)) && !/Burger Barn|Pizza Palace/.test(await html(p)));
  });
  await p.close();

  await browser.close(); srv.close();
  console.log(results.join('\n'));
  console.log(`\n${results.filter((r) => r.startsWith('PASS')).length} passed, ${results.filter((r) => r.startsWith('FAIL')).length} failed`);
})();
