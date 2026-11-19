// One password on every Proview site (19 Nov 2026): the sign-in page's "Forgot password?" says the password is the same
// on all Proview sites. Headless Chrome, the app served from this repo, Supabase mocked (no account, no network).
// Usage: node tests/ui/one_password_ui.test.js (a screenshot goes to the temp folder).
const puppeteer = require('/opt/npm-tools/node_modules/puppeteer-core');
const http = require('http'), fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.resolve(__dirname, '../../web/site'), PAGE = 'index.html', PORT = 8700 + Math.floor(Math.random() * 90), BASE = `http://127.0.0.1:${PORT}/`;
const results = []; const ok = (n, c) => results.push((c ? 'PASS ' : 'FAIL ') + n);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const TYPES = { '.html': 'text/html', '.js': 'application/javascript', '.mjs': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json', '.png': 'image/png', '.webmanifest': 'application/json' };
const srv = http.createServer((q, s) => { let f = path.join(ROOT, decodeURIComponent(new URL(q.url, BASE).pathname)); if (f.endsWith('/')) f += 'index.html';
  fs.readFile(f, (e, b) => { if (e) { s.writeHead(404); return s.end(); } s.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'text/plain' }); s.end(b); }); }).listen(PORT);
(async () => {
  const browser = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: 'new', args: ['--no-sandbox'] });
  const page = await browser.newPage(); const errs = [], resets = [];
  await page.setViewport({ width: 1280, height: 860 });
  page.on('pageerror', (e) => errs.push(e.message));
  page.on('dialog', (d) => d.dismiss());
  await page.setRequestInterception(true);
  page.on('request', (r) => {
    const u = r.url();
    if (u.startsWith(BASE) || /cdn\.jsdelivr\.net|esm\.sh|unpkg\.com|fonts\.(googleapis|gstatic)\.com/.test(u)) return r.continue();
    const j = (b, s = 200) => r.respond({ status: s, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' }, body: JSON.stringify(b) });
    if (r.method() === 'OPTIONS') return j({});
    if (u.includes('/auth/v1/recover')) { resets.push(u); return j({}); }
    if (u.includes('/auth/v1/')) return j({ message: 'not signed in' }, 401);
    if (u.includes('/rest/v1/') || u.includes('/functions/v1/')) return j([]);
    return j({});
  });
  await page.goto(BASE + PAGE, { waitUntil: 'networkidle2', timeout: 30000 }).catch(() => {});
  await wait(2500);
  const clickText = (re) => page.evaluate((src) => { const rx = new RegExp(src, 'i'); const el = [...document.querySelectorAll('a,button')].find((x) => rx.test(x.textContent.trim()) && x.offsetParent !== null); if (el) { el.click(); return true; } return false; }, re.source);
  ok('the sign-in page has "Forgot password?"', await page.evaluate(() => /Forgot (your )?password/i.test(document.body.innerText)));
  await clickText(/^Forgot (your )?password\??$/); await wait(800);
  const said = await page.evaluate(() => document.body.innerText);
  ok('"Forgot password?" says the password is the same on all Proview sites', /same on all Proview sites/.test(said));
  await page.screenshot({ path: path.join(os.tmpdir(), 'label-one-password.png') });
  ok('no page errors ' + JSON.stringify(errs), !errs.length);
  await browser.close(); srv.close();
  console.log(results.join('\n'));
  console.log(`\n${results.filter((x) => x.startsWith('PASS')).length} PASS, ${results.filter((x) => x.startsWith('FAIL')).length} FAIL`);
  process.exit(results.some((x) => x.startsWith('FAIL')) ? 1 : 0);
})().catch((e) => { console.error(e); srv.close(); process.exit(1); });
