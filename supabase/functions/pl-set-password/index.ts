// Proview Label: an owner/admin (or a Proview master) sets the password of a back-office login,
// so the person can sign in straight away without an email.
//   POST { member_id, password }   Authorization: Bearer <caller's session>
// Rules: master → anyone except another master; owner/admin → only people whose every business is one
// they own/administer; an admin can't change an owner's password.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const ORIGINS = ["https://label.proviewcrm.co.uk", "https://proview92.github.io"];

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  const h = cors(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...h, "Content-Type": "application/json" } });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });
    const { data: who } = await db.auth.getUser(auth.replace(/^Bearer\s+/i, ""));
    const caller = who?.user;
    if (!caller) return json({ error: "Please sign in again." }, 401);

    const { member_id, password } = await req.json().catch(() => ({}));
    const pw = String(password ?? "");
    if (!member_id) return json({ error: "Missing login." }, 400);
    if (pw.length < 8) return json({ error: "Use at least 8 characters for the password." }, 400);
    if (pw.length > 72) return json({ error: "That password is too long." }, 400);

    const { data: m } = await db.from("pl_members").select("*").eq("id", member_id).maybeSingle();
    if (!m) return json({ error: "That login no longer exists." }, 404);
    const email = String(m.email || "").toLowerCase();
    if (!email) return json({ error: "That login has no email." }, 400);

    // who is the caller?
    const { data: masterRow } = await db.from("pl_masters").select("user_id").eq("user_id", caller.id).maybeSingle();
    const isMaster = !!masterRow;
    const { data: mine } = await db.from("pl_members").select("org_id,role").eq("user_id", caller.id);
    const roleIn = (org: string) => (mine ?? []).find((x: any) => x.org_id === org)?.role ?? null;

    if (!isMaster) {
      const r = roleIn(m.org_id);
      if (!["owner", "admin"].includes(r ?? "")) return json({ error: "Only an owner or admin of this business can set passwords." }, 403);
      if (m.role === "owner" && r !== "owner") return json({ error: "Only an owner can change an owner's password." }, 403);
      // the same email in another business the caller doesn't run: hands off
      const { data: theirs } = await db.from("pl_members").select("org_id,role").eq("email", email);
      for (const t of theirs ?? []) {
        const cr = roleIn(t.org_id);
        if (!["owner", "admin"].includes(cr ?? "") || (t.role === "owner" && cr !== "owner"))
          return json({ error: "This person also has a login with another business, so only they (or Proview) can change their password." }, 403);
      }
    }

    // find their sign-in account, or create it
    let userId: string | null = m.user_id ?? null;
    if (!userId) {
      for (let page = 1; page <= 20 && !userId; page++) {
        const { data: list, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
        if (error) throw error;
        const u = list.users.find((x) => (x.email ?? "").toLowerCase() === email);
        if (u) userId = u.id;
        if (list.users.length < 1000) break;
      }
    }
    // never touch a Proview master's account (unless it's the caller's own)
    if (userId && userId !== caller.id) {
      const { data: tm } = await db.from("pl_masters").select("user_id").eq("user_id", userId).maybeSingle();
      if (tm) return json({ error: "That is a Proview master account; its password can only be changed by its owner." }, 403);
    }

    let created = false;
    if (userId) {
      const { error } = await db.auth.admin.updateUserById(userId, { password: pw, email_confirm: true });
      if (error) throw error;
    } else {
      const { data: nu, error } = await db.auth.admin.createUser({ email, password: pw, email_confirm: true, user_metadata: { name: m.name || "" } });
      if (error) throw error;
      userId = nu.user.id; created = true;
    }
    // link every login with this email to the account
    await db.from("pl_members").update({ user_id: userId }).eq("email", email).is("user_id", null);

    return json({ ok: true, created });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e).slice(0, 200) }, 500);
  }
});
