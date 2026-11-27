import { createClient } from "npm:@supabase/supabase-js@2.102.0";

type LoginTarget = { id: string | null; name: string; sector: string };

Deno.serve(async (request) => {
  const redirect = Deno.env.get("PANEL_INVITE_REDIRECT_URL");
  const origins = (Deno.env.get("PANEL_ALLOWED_ORIGINS") ?? "").split(",").map((origin) => origin.trim());
  const origin = request.headers.get("origin");
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  } as Record<string, string>;
  const reply = (status: number, code: string) => Response.json({ code }, { status, headers });

  const redirectUrl = redirect ? URL.parse(redirect) : null;
  if (!redirectUrl || redirectUrl.protocol !== "https:") return reply(503, "unavailable");
  if (origin && origin !== redirectUrl.origin && !origins.includes(origin)) return reply(403, "forbidden");
  if (origin) headers["Access-Control-Allow-Origin"] = origin;
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (request.method !== "POST") return reply(405, "method");

  const token = request.headers.get("Authorization")?.match(/^Bearer (\S+)$/i)?.[1];
  if (!token) return reply(401, "forbidden");
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return reply(503, "unavailable");
  const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
  try {
    const { data: { user }, error: authError } = await admin.auth.getUser(token);
    if (authError || !user?.email_confirmed_at) return reply(401, "forbidden");
    const input = await request.json().catch(() => null);
    const registration = typeof input?.registration === "string" ? input.registration.trim() : "";
    const email = typeof input?.email === "string" ? input.email.trim().toLowerCase() : "";
    const phone = typeof input?.phone === "string" ? input.phone.trim().replace(/[\s()+-]/g, "") : "";
    if (!/^\d{1,20}$/.test(registration) || email.length > 254 || !/^[^\s@]+@coamo\.com\.br$/.test(email) ||
        (phone && !/^(?:55)?[1-9]\d9\d{8}$/.test(phone))) {
      return reply(400, "invalid");
    }

    const lookup = { manager_id: user.id, employee_registration: registration, corporate_email: email };
    const { data, error } = await admin.rpc("panel_staff_activation_target", lookup);
    if (error) return reply(error.code === "42501" ? 403 : 409, error.code === "42501" ? "forbidden" : "conflict");

    const employee = data as LoginTarget;
    if (employee.id) {
      const { error } = await admin.rpc("panel_staff_activation_target", { ...lookup, attach_user: employee.id });
      return error ? reply(409, "link_failed") : reply(200, "linked");
    }

    const random = crypto.getRandomValues(new Uint8Array(24));
    const initialPassword = "Aa1!" + Array.from(random, (byte) => byte.toString(16).padStart(2, "0")).join("");
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password: initialPassword,
      email_confirm: true,
      user_metadata: {
        name: employee.name,
        requested_role: "operator",
        requested_sector: employee.sector,
        ...(phone ? { requested_phone: phone } : {}),
      },
    });
    if (createError || !created.user) return reply(409, "create_failed");

    const { error: attachError } = await admin.rpc("panel_staff_activation_target", {
      ...lookup,
      attach_user: created.user.id,
    });
    if (attachError && !["22023", "23505", "42501"].includes(attachError.code)) {
      return Response.json({ code: "link_pending", initialPassword }, { status: 202, headers });
    }
    if (attachError) {
      await admin.auth.admin.deleteUser(created.user.id);
      return reply(409, "link_failed");
    }
    return Response.json({ code: "activated", initialPassword }, { status: 201, headers });

  } catch {
    return reply(503, "unavailable");
  }
});
