// Handheld pairing, last step (see migrations/005_device_pairing.sql).
//
// The handheld keeps calling this with the secret it made when it showed its pairing code:
//   POST { secret } → { status: "waiting", code }        not paired yet
//                   → { status: "expired" }               code timed out: the handheld asks for a new one
//                   → { status: "paired", email, password, device_id, org_id, site_id, name, mode }
// Once a back-office login has paired the code, this makes a login used only by that handheld
// (<device_id>@devices.label.proviewcrm.co.uk, random password) and hands it over. Asking again with the
// same secret within the hour gives a fresh password, so a lost reply doesn't strand the handheld.
//
// Deploy with verify_jwt = false (the handheld isn't signed in yet).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "content-type": "application/json" } });
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const randomPassword = () => { const r = new Uint8Array(32); crypto.getRandomValues(r); return hex(r.buffer); };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const { secret } = await req.json().catch(() => ({}));
  if (typeof secret !== "string" || secret.length < 32 || secret.length > 200) return json({ error: "Bad request" }, 400);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const hash = hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret)));
  const { data: p, error } = await admin.from("pl_pairings").select("*").eq("secret_hash", hash).maybeSingle();
  if (error) return json({ error: error.message }, 500);
  if (!p || new Date(p.expires_at) < new Date()) return json({ status: "expired" });
  if (!p.claimed_at) return json({ status: "waiting", code: p.code });

  // already handed over once: only hand over again while the handheld is still paired (not removed since),
  // and keep any changes made in the back-office since (name, location, mode)
  let cur: Record<string, string> | null = null;
  if (p.user_id) {
    const { data: still } = await admin.from("pl_devices").select("*").eq("id", p.device_id).maybeSingle();
    if (!still) return json({ status: "expired" });
    cur = still;
  }
  const email = `${p.device_id}@devices.label.proviewcrm.co.uk`.toLowerCase();
  const password = randomPassword();
  let uid: string | null = p.user_id;
  if (!uid) {
    const c = await admin.auth.admin.createUser({ email, password, email_confirm: true, app_metadata: { pl_device: p.device_id } });
    if (c.error) {
      const { data: found } = await admin.rpc("pl_auth_uid", { p_email: email });
      if (!found) return json({ error: c.error.message }, 500);
      uid = found as string;
    } else uid = c.data.user!.id;
  }
  const u = await admin.auth.admin.updateUserById(uid!, { password });
  if (u.error) return json({ error: u.error.message }, 500);

  const dev = cur || { id: p.device_id, user_id: uid, org_id: p.org_id, site_id: p.site_id, name: p.name || "Handheld", mode: p.mode || "easy", paired_by: p.claimed_by };
  if (!cur) {
    const ins = await admin.from("pl_devices").insert(dev);
    if (ins.error) return json({ error: ins.error.message }, 500);
    await admin.from("pl_pairings").update({ user_id: uid }).eq("code", p.code);
  }

  return json({ status: "paired", email, password, device_id: p.device_id, org_id: dev.org_id, site_id: dev.site_id, name: dev.name, mode: dev.mode });
});
