// Deno test of an app's sso-login edge function (Label: pl_*, QR Menu: pq_*) with the biz claim (MASTER_OPEN_SPEC.md).
// Real Ed25519 signatures: the test makes a key pair, puts its public half in a copy of index.ts in place of the
// production key (only that one line changes) and signs assertions with the private half. Supabase (PostgREST and
// GoTrue admin) is an in-memory mock behind fetch. Usage: deno run -A sso_login_test.ts <index.ts> <label|qrmenu>
const [SRC, APP] = Deno.args;
const PFX = APP === "label" ? "pl" : "pq";
const out: string[] = []; const ok = (c: unknown, m: string) => out.push((c ? "PASS " : "FAIL ") + APP + ": " + m);
Deno.env.set("SUPABASE_URL", "http://db.mock"); Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service");

const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
const pub = await crypto.subtle.exportKey("jwk", kp.publicKey);
const other = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
async function assertion(claims: Record<string, unknown>, key = kp.privateKey) {
  const now = Math.floor(Date.now() / 1000);
  const p = new TextEncoder().encode(JSON.stringify({ iss: "proview-account", aud: APP, mode: "login", iat: now, exp: now + 120, jti: crypto.randomUUID(), ...claims }));
  return b64u(p) + "." + b64u(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, p)));
}

// ---------- in-memory Supabase ----------
const MASTER = "altun@proviewtech.co.uk";
const BIZ_A = APP === "label" ? "org_a" : "11111111-2222-4333-8444-555555555555";
const BIZ_GONE = APP === "label" ? "org_gone" : "99999999-2222-4333-8444-555555555555";
const T: Record<string, any[]> = {
  [PFX + "_masters"]: [{ email: MASTER }],
  [PFX + "_orgs"]: [{ id: BIZ_A, name: "Burger Barn" }],
  [PFX + "_sso_used"]: [],
};
const ENT: Record<string, any> = { [MASTER]: { ok: true, user_id: "u-master" }, "owner@bb.test": { ok: true, user_id: "u-owner" } };
const log: string[] = [];
const J = (s: number, b?: unknown, h: Record<string, string> = {}) => new Response(b === undefined ? null : JSON.stringify(b), { status: s, headers: { "content-type": "application/json", ...h } });
globalThis.fetch = (async (input: any, init?: any) => {
  const req = input instanceof Request ? input : new Request(input, init);
  const u = new URL(req.url); const body = req.method === "GET" || req.method === "HEAD" ? null : await req.text();
  log.push(req.method + " " + u.pathname + u.search);
  if (u.pathname === "/rest/v1/rpc/sso_entitled") { const e = String(JSON.parse(body!).p_email).toLowerCase().trim(); return J(200, ENT[e] || { ok: false, reason: "No account for this email." }); }
  if (u.pathname === "/auth/v1/admin/generate_link") { const e = JSON.parse(body!).email; return J(200, { action_link: "x", email_otp: "1", hashed_token: "HASH-" + e, redirect_to: "", verification_type: "magiclink", id: "u", email: e }); }
  if (u.pathname === "/auth/v1/admin/users") return J(200, { id: "new" });
  const m = u.pathname.match(/^\/rest\/v1\/(\w+)$/);
  if (m && T[m[1]]) {
    const t = T[m[1]];
    if (req.method === "POST") { const row = JSON.parse(body!); if (t.some((r) => r.jti === row.jti)) return J(409, { code: "23505", message: "duplicate key" }); t.push(row); return J(201, []); }
    if (req.method === "DELETE") return J(204);
    let rows = t;
    for (const [k, v] of u.searchParams) { if (k === "select") continue; const mm = v.match(/^eq\.(.*)$/); if (mm) rows = rows.filter((r) => String(r[k]) === mm[1]); }
    if ((req.headers.get("accept") || "").includes("vnd.pgrst.object")) return rows.length === 1 ? J(200, rows[0]) : J(406, { code: "PGRST116", message: "0 rows", details: "The result contains 0 rows" });
    return J(200, rows);
  }
  return J(404, { message: "unmocked " + u.pathname });
}) as typeof fetch;

// ---------- load the function with the test public key ----------
const src = await Deno.readTextFile(SRC);
const keyLine = /const PUBLIC_JWK = \{[^}]*\};/;
ok(keyLine.test(src) && src.includes('x: "yAcboFvNf5YwMEut72aLrh8OhptnUkGgHFExuQaD868"'), "production public key unchanged in the file");
const tmp = await Deno.makeTempFile({ suffix: ".ts" });
await Deno.writeTextFile(tmp, src.replace(keyLine, `const PUBLIC_JWK = ${JSON.stringify({ crv: pub.crv, x: pub.x, kty: pub.kty })};`));
let handler: (r: Request) => Promise<Response> = async () => J(500);
(Deno as any).serve = (h: any) => { handler = h; return {}; };
await import("file://" + tmp);
const call = async (a: string) => { const r = await handler(new Request("http://fn/", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ assertion: a }) })); return { status: r.status, body: await r.json() }; };

// ---------- tests ----------
let r = await call(await assertion({ email: MASTER, biz: BIZ_A }));
ok(r.status === 200 && r.body.token_hash === "HASH-" + MASTER && r.body.open === BIZ_A, `master + biz → signed in and open=${BIZ_A} (${JSON.stringify(r.body)})`);
ok(log.some((l) => l.startsWith(`GET /rest/v1/${PFX}_masters`)), "master checked against " + PFX + "_masters");

r = await call(await assertion({ email: MASTER.toUpperCase(), biz: BIZ_A }));
ok(r.status === 200 && r.body.open === BIZ_A, "master email in capitals still recognised");

r = await call(await assertion({ email: MASTER }));
ok(r.status === 200 && r.body.token_hash && !("open" in r.body), "master without biz → signed in, no open (old link → portal page)");

r = await call(await assertion({ email: "owner@bb.test", biz: BIZ_A }));
ok(r.status === 200 && r.body.token_hash === "HASH-owner@bb.test" && !("open" in r.body), "biz on a non-master assertion is ignored (owner signed in as usual, no open)");

const before = T[PFX + "_sso_used"].length;
r = await call(await assertion({ email: MASTER, biz: BIZ_GONE }));
ok(r.status === 404 && /no longer exists/.test(r.body.error) && T[PFX + "_sso_used"].length === before, "business that doesn't exist → 404, link not used up");

r = await call(await assertion({ email: MASTER, biz: { id: BIZ_A } }));
ok(r.status === 200 && !("open" in r.body), "biz that isn't a string is ignored");

r = await call(await assertion({ email: MASTER, biz: BIZ_A }, other.privateKey));
ok(r.status === 401 && !r.body.token_hash, "assertion signed with another key → 401");

const good = await assertion({ email: MASTER, biz: BIZ_A });
const [p, s] = good.split(".");
const claims = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(p.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((p.length + 3) % 4)), (c) => c.charCodeAt(0))));
claims.biz = BIZ_GONE; const forged = b64u(new TextEncoder().encode(JSON.stringify(claims))) + "." + s;
r = await call(forged);
ok(r.status === 401, "biz changed after signing → signature fails, 401");

r = await call(good); ok(r.status === 200 && r.body.open === BIZ_A, "fresh assertion works");
r = await call(good); ok(r.status === 401 && /already used/.test(r.body.error), "same assertion twice → 401 (single use)");

r = await call(await assertion({ email: MASTER, biz: BIZ_A, aud: "signage" }));
ok(r.status === 401, "assertion for another app → 401");
r = await call(await assertion({ email: "nobody@x.test", biz: BIZ_A }));
ok(r.status === 403 && !r.body.token_hash, "not entitled → 403 (biz doesn't help)");
const now = Math.floor(Date.now() / 1000);
r = await call(await assertion({ email: MASTER, biz: BIZ_A, iat: now - 400, exp: now - 100 }));
ok(r.status === 401, "expired assertion → 401");
r = await call(await assertion({ email: MASTER, biz: BIZ_A, mode: "check" }));
ok(r.status === 200 && r.body.ok === true && !r.body.token_hash && !("open" in r.body), "mode check unchanged (no token, no open)");

await Deno.remove(tmp);
console.log(out.join("\n"));
const f = out.filter((x) => x.startsWith("FAIL")).length;
console.log(`\n${out.length - f} passed, ${f} failed`);
if (f) Deno.exit(1);
