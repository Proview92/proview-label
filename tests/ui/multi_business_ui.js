// Headless tests of MULTI_BUSINESS_PICKER_STANDARD.md (with OWNER UPDATE 07:47 / 07:47b and No Locations page) in the Label back-office (web/site/index.html, live build) against a
// mocked Supabase: a person in two businesses (A = Burger Barn with 2 locations, B = Pizza Palace with 1).
//   node tests/ui/multi_business_ui.js web/site [shots dir]
const puppeteer = require('/opt/npm-tools/node_modules/puppeteer-core');
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = process.argv[2], PORT = 8132, SHOTS = process.argv[3] || require('os').tmpdir();
const srv = http.createServer((q, r) => { const f = path.join(ROOT, decodeURIComponent(q.url.split('?')[0]).replace(/^\/$/, '/index.html')); fs.readFile(f, (e, b) => { if (e) { r.writeHead(200, { 'content-type': 'text/html' }); return r.end('<p>blank</p>'); } r.writeHead(200, { 'content-type': 'text/html' }); r.end(b); }); });
const UID = '3340d285-2ca8-4b98-890b-a237c9867297';
const fakeJwt = (em) => { const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url'); return b({ alg: 'HS256', typ: 'JWT' }) + '.' + b({ sub: UID, role: 'authenticated', email: em, exp: 4102444800 }) + '.sig'; };
const user = (em) => ({ id: UID, email: em, aud: 'authenticated', role: 'authenticated', email_confirmed_at: '2026-11-08T00:00:00Z' });
const session = (em) => ({ access_token: fakeJwt(em), refresh_token: 'r', token_type: 'bearer', expires_in: 3600, expires_at: 4102444800, user: user(em) });
const results = []; const ok = (n, c, x) => results.push((c ? 'PASS ' : 'FAIL ') + n + (x && !c ? ' :: ' + x : ''));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MASTER = 'altun@proviewtech.co.uk', TWO = 'sam@two.test', ONE = 'owner@burgerbarn.test';
const ORGS = { org_a: 'Burger Barn', org_b: 'Pizza Palace' };
const SITES = [['site_a1', 'org_a', 'Camden Kitchen'], ['site_a2', 'org_a', 'Soho Kitchen'], ['site_b1', 'org_b', 'Leeds Pizzeria']];
const rec = (id, kind, orgId, data) => ({ id, kind, org_id: orgId, data: { id, orgId, ...data }, deleted: false, updated_at: '2026-11-08T00:00:00Z' });
const RECORDS = [...SITES.map(([id, o, n]) => rec(id, 'sites', o, { name: n, address: n + ' road', region: '' })),
  rec('p_a', 'products', 'org_a', { name: 'Beef patty secret', categoryId: '', allergens: [] }), rec('p_b', 'products', 'org_b', { name: 'Margherita secret', categoryId: '', allergens: [] })];
const licOf = (o) => SITES.filter((s) => s[1] === o).map(([id]) => ({ id, licence_type: 'lifetime', licence_starts_at: null, licence_expires_at: null }));
const org = (id, role, extra = {}) => ({ id, name: ORGS[id], settings: {}, suspended: false, role, site_ids: [], member_id: role === 'master' ? null : 'm-' + id, features: {},
  trial_ends_at: null, trial_expired: false, licensed: true, no_licence: false, locked: false, sites: licOf(id), ...extra });

async function run(browser, opts, body) {
  const st = { calls: [], sso: null, recs: RECORDS.map((r) => ({ ...r, data: { ...r.data } })) };
  const page = await browser.newPage(); const errs = [];
  await page.setViewport({ width: 1366, height: 900 });
  page.on('pageerror', (e) => errs.push(e.message));
  await page.setRequestInterception(true);
  page.on('request', (rq) => {
    const u = rq.url(); if (!u.includes('supabase.co')) return rq.continue();
    const U = new URL(u), p = U.pathname, m = rq.method(), hOrg = rq.headers()['x-pl-org'] || '';
    if (m !== 'OPTIONS') st.calls.push(m + ' ' + p + U.search + ' [' + hOrg + ']');
    const res = (s, b) => rq.respond({ status: s, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }, body: JSON.stringify(b) });
    if (m === 'OPTIONS') return res(200, {});
    if (p === '/functions/v1/sso-login') { st.sso = JSON.parse(rq.postData()); return res(200, opts.ssoReply); }
    if (p === '/auth/v1/verify') return res(200, session(opts.email));
    if (p === '/rest/v1/rpc/pl_whoami') {
      const orgs = opts.master ? Object.keys(ORGS).filter((id) => id === hOrg).map((id) => org(id, 'master')) : opts.orgs;
      return res(200, { email: opts.email, master: !!opts.master, trial_used: false, orgs });
    }
    if (p === '/rest/v1/pl_records' && m === 'GET') {
      const mine = opts.master ? (hOrg ? [hOrg] : []) : opts.orgs.map((o) => o.id);
      const want = (U.searchParams.get('org_id') || '').replace(/^eq\./, '');
      let rows = st.recs.filter((r) => mine.includes(r.org_id));
      if (want) rows = rows.filter((r) => r.org_id === want);
      const kin = U.searchParams.get('kind'); if (kin) { const ks = kin.replace(/^in\.\(|\)$/g, '').split(','); rows = rows.filter((r) => ks.includes(r.kind)); }
      if ((U.searchParams.get('select') || '') === 'id') return res(200, rows.map((r) => ({ id: r.id })));
      return res(200, rows);
    }
    if (p === '/rest/v1/pl_records') { const body = rq.postData() || ''; st.writes = (st.writes || []).concat(body);
      // keep upserts, as the server does (a test changes a copy: RECORDS is restored per run below)
      try { [].concat(JSON.parse(body)).forEach((r) => { if (!r || !r.id) return; const i = st.recs.findIndex((x) => x.id === r.id); const row = { ...(st.recs[i] || {}), ...r, updated_at: new Date().toISOString() }; if (i >= 0) st.recs[i] = row; else st.recs.push(row); }); } catch (e) {}
      return res(201, []); }
    if (p === '/rest/v1/pl_devices' || p === '/rest/v1/pl_members') return res(200, []);
    if (p === '/rest/v1/rpc/pl_plans') return res(200, {});
    if (p.startsWith('/auth/v1/user')) return res(200, user(opts.email));
    if (p.startsWith('/auth/v1/logout')) return res(204, {});
    return res(404, { message: 'unmocked ' + p });
  });
  await page.goto(`http://127.0.0.1:${PORT}/blank`, { waitUntil: 'domcontentloaded' });
  await page.evaluate((s, ls) => { localStorage.clear(); sessionStorage.clear(); if (s) localStorage.setItem('pv-label-auth', JSON.stringify(s)); Object.entries(ls || {}).forEach(([k, v]) => localStorage.setItem(k, v)); },
    opts.ssoReply ? null : session(opts.email), opts.ls);
  await page.goto(`http://127.0.0.1:${PORT}/index.html${opts.url || '#overview'}`, { waitUntil: 'networkidle0' }); await sleep(900);
  await body(page, st);
  ok(opts.name + ': no page errors', !errs.length, errs.join(' | '));
  await page.close();
}
const text = (p) => p.evaluate(() => document.querySelector('#main') ? document.querySelector('#main').innerText : document.body.innerText);
const opts = (p) => p.$$eval('#sitePick option', (o) => o.map((x) => x.textContent));
const picked = (p) => p.$eval('#sitePick', (s) => s.options[s.selectedIndex].textContent);
const box = (p) => p.$eval('#sitePick', (s) => s.disabled ? s.textContent.trim() : null).catch(() => null);
const choose = async (p, label, sel = '#sitePick') => { await p.evaluate((l, q) => { const s = document.querySelector(q); const o = [...s.options].find((x) => x.textContent === l); s.value = o.value; s.dispatchEvent(new Event('change')); }, label, sel); await sleep(400); };
const page = async (p, h) => { await p.evaluate((x) => { location.hash = x; }, h); await sleep(400); return text(p); };
const both = (role = 'owner', a = {}, b = {}) => [org('org_a', role, a), org('org_b', role, b)];
const KEY = 'pvl-site:' + TWO;
const HDR = JSON.stringify(['Burger Barn', 'Pizza Palace']);
const plain = async (p, who) => {
  const h = await p.$eval('#top', (e) => e.outerHTML);
  ok(who + ': header has no location breakdown (no optgroup, ▸, All my locations, Choose/Switch location)', !/optgroup|▸|All my locations|All locations|Choose location|Switch location/.test(h), h.slice(0, 300));
};

(async () => {
  await new Promise((r) => srv.listen(PORT, r));
  const browser = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: 'new', args: ['--no-sandbox'] });

  // 1. two businesses: business names only; lands in the last-used one
  await run(browser, { name: 'two: last used B', email: TWO, orgs: both(), ls: { [KEY]: 'org:org_b' } }, async (p) => {
    ok('two: dropdown lists business names only, by name', JSON.stringify(await opts(p)) === HDR, JSON.stringify(await opts(p)));
    ok('two: select aria-label "Business" and a hidden label "Business"', await p.$eval('#sitePick', (s) => s.getAttribute('aria-label') === 'Business' && !s.disabled) && await p.$eval('label[for=sitePick]', (l) => l.textContent.trim() === 'Business' && l.classList.contains('sr')));
    await plain(p, 'two');
    ok('two: lands in the last-used business (Pizza Palace)', await picked(p) === 'Pizza Palace', await picked(p));
    await p.screenshot({ path: SHOTS + '/label-two.png' });
    await p.click('#tbOut'); await sleep(800);
    ok('two: the business used last is kept through sign-out', await p.evaluate((k) => localStorage.getItem(k), KEY) === 'org:org_b');
  });
  await run(browser, { name: 'two: remembered location (older build)', email: TWO, orgs: both(), ls: { [KEY]: 'site_b1' } }, async (p) => {
    ok('two: a remembered location opens its whole business', await picked(p) === 'Pizza Palace', await picked(p));
  });
  await run(browser, { name: 'two: SSO', email: TWO, orgs: both(), ls: { [KEY]: 'org:org_b' }, url: '#pv_sso=TOK', ssoReply: { token_hash: 'h', email: TWO } }, async (p) => {
    ok('two SSO: lands in the last-used business', await picked(p) === 'Pizza Palace', await picked(p));
  });
  await run(browser, { name: 'two: nothing remembered', email: TWO, orgs: both() }, async (p) => {
    ok('two: nothing remembered → the first business (Burger Barn)', await picked(p) === 'Burger Barn', await picked(p));
  });

  // 2. switching; a business covers all its locations and never mixes with the other
  await run(browser, { name: 'two: switch', email: TWO, orgs: both(), ls: { [KEY]: 'org:org_a' } }, async (p) => {
    let t = await text(p);
    ok('A: dashboard has both A locations, nothing of B', /Camden Kitchen/.test(t) && /Soho Kitchen/.test(t) && !/Leeds Pizzeria|Pizza Palace/.test(t), t.slice(0, 300));
    t = await page(p, 'products');
    ok('A: products of A only', /Beef patty secret/.test(t) && !/Margherita secret/.test(t));
    await choose(p, 'Pizza Palace');
    ok('switch to B: picked', await picked(p) === 'Pizza Palace');
    t = await page(p, 'products');
    ok('switch to B: products of B only', /Margherita secret/.test(t) && !/Beef patty secret/.test(t));
    t = await page(p, 'overview');
    ok('switch to B: dashboard of B only', /Pizza Palace/.test(t) && !/Camden Kitchen|Soho Kitchen|Burger Barn/.test(t) && !/3 locations combined/.test(t), t.slice(0, 300));
    ok('switch to B: remembered by email', await p.evaluate((k) => localStorage.getItem(k), KEY) === 'org:org_b');
    await choose(p, 'Burger Barn');
    t = await page(p, 'products');
    ok('switch back to A: A only', /Beef patty secret/.test(t) && !/Margherita/.test(t));
  });

  // 3. fallback when A is unusable
  await run(browser, { name: 'fallback locked', email: TWO, orgs: both('owner', { locked: true, licensed: false, no_licence: true }), ls: { [KEY]: 'org:org_a' } }, async (p) => {
    const t = await text(p);
    ok('A locked: lands in Pizza Palace instead (not signed out)', await picked(p) === 'Pizza Palace' && /Pizza Palace/.test(t) && !/Burger Barn/.test(t), await picked(p));
    ok('A locked: only usable businesses listed, one left = disabled box (07:55)', await box(p) === 'Pizza Palace', JSON.stringify(await opts(p)));
    ok('A locked: fallback not saved over the last-used business', await p.evaluate((k) => localStorage.getItem(k), KEY) === 'org:org_a');
  });
  await run(browser, { name: 'fallback suspended', email: TWO, orgs: both('owner', { suspended: true }), ls: { [KEY]: 'site_a2' } }, async (p) => {
    ok('A suspended: lands in Pizza Palace', await picked(p) === 'Pizza Palace', await picked(p));
  });
  await run(browser, { name: 'fallback no locations', email: TWO, orgs: [org('org_a', 'manager', { site_ids: [] }), org('org_b', 'owner')], ls: { [KEY]: 'org:org_a' } }, async (p) => {
    ok('A has no locations for them: lands in Pizza Palace (one business left: disabled box)', await box(p) === 'Pizza Palace', JSON.stringify(await opts(p)));
    const t0 = await text(p), t1 = await page(p, 'products');
    ok('A has no locations: not signed out, nothing of A', /Labels printed today/.test(t0) && !/Beef patty/.test(t1), t0.slice(0, 200));
  });
  await run(browser, { name: 'fallback B locked', email: TWO, orgs: both('owner', {}, { locked: true }), ls: { [KEY]: 'org:org_b' } }, async (p) => {
    ok('B locked, last used B: lands in Burger Barn', await picked(p) === 'Burger Barn', await picked(p));
  });
  await run(browser, { name: 'none usable', email: TWO, orgs: [org('org_a', 'manager', { site_ids: [] }), org('org_b', 'manager', { site_ids: [] })] }, async (p) => {
    ok('no usable business (no locations anywhere): signed out', /Sign in|Email/i.test(await p.evaluate(() => document.body.innerText)) && !(await p.$('#sitePick')));
  });

  // 4. one business: its name in a disabled box
  await run(browser, { name: 'one business', email: ONE, orgs: [org('org_a', 'owner')] }, async (p) => {
    ok('one business (2 locations): disabled box with the business name', await box(p) === 'Burger Barn', JSON.stringify(await opts(p)));
    await plain(p, 'one business');
    ok('one business: both locations on the dashboard', /Camden Kitchen/.test(await text(p)) && /Soho Kitchen/.test(await text(p)));
  });
  await run(browser, { name: 'one location', email: ONE, orgs: [org('org_b', 'owner')] }, async (p) => {
    ok('one business (1 location): disabled box with the business name', await box(p) === 'Pizza Palace');
  });

  // 5. master-open: the opened business's name in the same disabled box
  await run(browser, { name: 'master open', email: MASTER, master: true, url: '#pv_sso=T', ssoReply: { token_hash: 'h', email: MASTER, open: 'org_a' } }, async (p) => {
    const t = await p.evaluate(() => document.body.innerText);
    ok('master open: inside Burger Barn as Proview', /Viewing Burger Barn as Proview/.test(t));
    ok('master open: disabled box with the business name', await box(p) === 'Burger Barn');
    ok('master open: no other business', !/Pizza Palace|Leeds/.test(await p.evaluate(() => document.documentElement.outerHTML)));
  });

  // 6. no Locations page, for every role; Settings → This location instead (07:47b: licence wording says business)
  const noLoc = async (p, who) => {
    ok(who + ': no Locations item in the menu', !(await p.$$eval('.side .nav a', (a) => a.some((x) => /Locations/.test(x.textContent)))), await p.$$eval('.side .nav a', (a) => a.map((x) => x.textContent).join('|')));
    for (const h of ['devices', 'sites', 'locations']) {
      await p.evaluate((x) => { location.hash = x; }, h); await sleep(350);
      ok(who + ': old #' + h + ' goes to the Dashboard', /Labels printed today/.test(await text(p)) && !/Locations & devices/.test(await text(p)));
    }
  };
  await run(browser, { name: 'no Locations: owner', email: TWO, orgs: both(), ls: { [KEY]: 'org:org_a' } }, async (p, st) => {
    await noLoc(p, 'owner');
    await page(p, 'settings');
    ok('owner: Settings has a location select (A has 2 locations), default the first', JSON.stringify(await p.$$eval('#tlSite option', (o) => o.map((x) => x.textContent))) === JSON.stringify(['Camden Kitchen', 'Soho Kitchen']) && await p.$eval('#tlName', (i) => i.value) === 'Camden Kitchen');
    ok('owner: the page\'s location select has aria-label "Location", no "All" entry', await p.$eval('#tlSite', (s) => s.getAttribute('aria-label') === 'Location' && ![...s.options].some((o) => /All/.test(o.textContent))));
    await choose(p, 'Soho Kitchen', '#tlSite');
    await p.reload({ waitUntil: 'networkidle0' }); await sleep(900); await page(p, 'settings');
    ok('owner: the page\'s location choice is remembered per business on the device', await p.$eval('#tlSite', (s) => s.options[s.selectedIndex].textContent) === 'Soho Kitchen');
    ok('owner: This location shows the chosen location', await p.$eval('#tlName', (i) => i.value) === 'Soho Kitchen' && await p.$eval('#tlAddr', (i) => i.value) === 'Soho Kitchen road');
    ok('owner: This location shows its licence, in business wording', /Lifetime/.test(await p.$eval('#tlLic', (e) => e.innerText)) && /each business needs its own licence/.test(await p.$eval('#tlLic', (e) => e.innerText)));
    ok('owner: header still the business only', await picked(p) === 'Burger Barn');
    await p.$eval('#tlName', (i) => { i.value = 'Soho Grill'; }); await p.$eval('#tlAddr', (i) => { i.value = '1 Dean St'; });
    st.writes = []; await p.click('#tlSave'); await sleep(1500);
    ok('owner: This location saves to that location', await p.$eval('#tlName', (i) => i.value) === 'Soho Grill' && await p.$eval('#tlSite', (s) => s.options[s.selectedIndex].textContent) === 'Soho Grill');
    ok('owner: the save is sent to the server for that location only', st.writes.some((w) => /Soho Grill/.test(w) && /1 Dean St/.test(w) && /site_a2/.test(w)) && !st.writes.some((w) => /site_a1/.test(w) && /1 Dean St/.test(w)), st.writes.join('\n').slice(0, 300));
    await choose(p, 'Pizza Palace'); await page(p, 'settings');
    ok('owner: one-location business uses it without asking', !(await p.$('#tlSite')) && await p.$eval('#tlName', (i) => i.value) === 'Leeds Pizzeria');
    const t = await page(p, 'handhelds');
    ok('owner: Handhelds page kept (pairing), no locations list', /Pair handheld/.test(t) && !/Address \(printed/.test(t));
  });
  await run(browser, { name: 'no Locations: locked', email: ONE, orgs: [org('org_b', 'owner', { sites: [{ id: 'site_b1', licence_type: null }] })], url: '#settings' }, async (p) => {
    ok('owner: This location offers Buy online for an unlicensed location', /Buy online/.test(await p.$eval('#tlLic', (e) => e.innerText)) && !!(await p.$('#tlLic [data-buy]')));
    ok('07:47b: banner says each business needs its own licence', /each business needs its own licence/.test(await text(p)) && !/each location needs its own licence/i.test(await text(p)));
  });
  await run(browser, { name: 'no Locations: manager', email: TWO, orgs: [org('org_a', 'manager', { site_ids: ['site_a1'] })] }, async (p) => {
    await noLoc(p, 'manager');
  });
  await run(browser, { name: 'no Locations: master', email: MASTER, master: true, url: '#pv_sso=T', ssoReply: { token_hash: 'h', email: MASTER, open: 'org_a' } }, async (p) => {
    await noLoc(p, 'master');
    await page(p, 'settings');
    ok('master: This location has the select, Licence… and Rename business', !!(await p.$('#tlSite')) && !!(await p.$('#thisLoc [data-licf]')) && !!(await p.$('#thisLoc [data-eo]')) && !!(await p.$('#tlSave')));
  });

  // business wording (owner, 12 Nov 2026: the licence portal says Businesses)
  await run(browser, { name: 'wording master', email: MASTER, master: true, url: '#overview' }, async (p) => {
    const t = await p.evaluate(() => document.body.innerText);
    ok('master direct: "Open a business from the licence portal", businesses added and linked there', /Open a business from the licence portal/.test(t) && /Businesses are added and linked there too \(New business, Link with another business\)/.test(t) && !/Open a location/.test(t), t.slice(0, 300));
  });
  await run(browser, { name: 'wording owner', email: ONE, orgs: [org('org_a', 'owner')], url: '#settings' }, async (p) => {
    ok('owner: This location says businesses are set up by Proview', /Businesses are set up and linked by Proview/.test(await text(p)) && /This location/.test(await text(p)));
  });

  await browser.close(); srv.close();
  console.log(results.join('\n'));
  console.log(`\n${results.filter((r) => r.startsWith('PASS')).length} passed, ${results.filter((r) => r.startsWith('FAIL')).length} failed`);
})();
