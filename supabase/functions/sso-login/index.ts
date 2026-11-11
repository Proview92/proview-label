// "Sign in with Proview account" — receiving end for Proview Label.
//
// dashboard.proviewcrm.co.uk signs a short-lived Ed25519 assertion "this person controls
// <email>" (only after they signed in to their confirmed Proview account). This function checks
// the signature, checks the email is a Proview master or a back-office login here (public.sso_entitled), and returns a
// one-time magic-link token the app exchanges for a normal session with
// supabase.auth.verifyOtp({ token_hash, type: "magiclink" }). Device staff (PIN only) have no back-office login.
//
//   POST { assertion } → { token_hash, email }      (assertion mode "login", single use)
//   POST { assertion } → { ok, reason }             (assertion mode "check": can this person sign in?)
//
// Opening a customer from the licence portal (MASTER_OPEN_SPEC.md): the portal's sso-assert adds a claim
// biz: "<business id>" (lic_accounts.ext_id = pl_orgs.id) only for a licence admin. It is honoured only when the
// asserted email is this app's master (public.pl_masters, the rule behind pl_is_master()); then the reply also has
// open: "<business id>" and the back-office opens exactly that business (x-pl-org header). A biz claim on anyone
// else's assertion is ignored. A business that no longer exists is refused before the link is used up.
//
// Deploy with verify_jwt = false (the caller isn't signed in yet). Only the public key lives here.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const APP = "label";
const PUBLIC_JWK = { crv: "Ed25519", x: "yAcboFvNf5YwMEut72aLrh8OhptnUkGgHFExuQaD868", kty: "OKP" };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));

let KEY: CryptoKey | null = null;
async function verify(token: string) {
  const [p, s] = String(token || "").split(".");
  if (!p || !s) return null;
  KEY ??= await crypto.subtle.importKey("jwk", PUBLIC_JWK, { name: "Ed25519" }, false, ["verify"]);
  const raw = unb64u(p);
  if (!(await crypto.subtle.verify({ name: "Ed25519" }, KEY, unb64u(s), raw))) return null;
  const c = JSON.parse(new TextDecoder().decode(raw));
  const now = Math.floor(Date.now() / 1000);
  if (c.iss !== "proview-account" || c.aud !== APP || !c.email || !c.jti) return null;
  if (!(c.exp > now) || c.exp - c.iat > 300 || c.iat > now + 60) return null;
  return c as { email: string; mode: string; jti: string; exp: number; biz?: unknown };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const { assertion } = await req.json().catch(() => ({}));
    const c = await verify(assertion).catch(() => null);
    if (!c) return json({ error: "That sign-in link has expired. Please try again." }, 401);

    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: ent, error } = await db.rpc("sso_entitled", { p_email: c.email });
    if (error) throw error;
    if (c.mode === "check") return json({ ok: !!ent?.ok, reason: ent?.reason || "" });
    if (!ent?.ok) return json({ error: ent?.reason || "This email can’t use a Proview account here." }, 403);

    // the business the master asked to open (licence portal "Open in Proview Label"); ignored for anyone else
    let open: string | null = null;
    const biz = typeof c.biz === "string" ? c.biz.trim() : "";
    if (biz && biz.length <= 100) {
      const m = await db.from("pl_masters").select("email").eq("email", String(c.email).toLowerCase()).maybeSingle();
      if (m.error) throw m.error;
      if (m.data) {
        const o = await db.from("pl_orgs").select("id").eq("id", biz).maybeSingle();
        if (o.error) throw o.error;
        if (!o.data) return json({ error: "That business no longer exists in Proview Label. Refresh the licence portal and try again." }, 404);
        open = o.data.id;
      }
    }

    const used = await db.from("pl_sso_used").insert({ jti: c.jti, email: c.email });
    if (used.error) return json({ error: "That sign-in link was already used. Please try again." }, 401);
    await db.from("pl_sso_used").delete().lt("at", new Date(Date.now() - 864e5).toISOString());

    if (!ent.user_id && ent.create) {
      const r = await db.auth.admin.createUser({ email: c.email, email_confirm: true });
      if (r.error && !/already/i.test(r.error.message)) throw r.error;
    }
    const link = await db.auth.admin.generateLink({ type: "magiclink", email: c.email });
    if (link.error) throw link.error;
    return json({ token_hash: link.data.properties.hashed_token, email: c.email, ...(open ? { open } : {}) });
  } catch (e) {
    console.error(e);
    return json({ error: "Sign-in failed. Please try again." }, 500);
  }
});
