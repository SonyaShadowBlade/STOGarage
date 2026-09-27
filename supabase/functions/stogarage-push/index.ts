import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { sendNotification } from "npm:web-push-neo@0.1.2";

const VAPID_PUBLIC_KEY = "BE2jGs15xBtOr36VHiHeYoA8y-uQ7ypcNf3tM5qgnUfuUt2X0cDMyauwqErHGSlPp3Q89CIM3SsxffkmnMAY9-U";
const VAPID_SUBJECT = "mailto:stogarage@example.com";
const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY")!;
const admin = createClient(supabaseUrl, serviceRoleKey);

function authorized(req: Request) {
  return req.headers.get("authorization") === "Bearer " + serviceRoleKey;
}

async function recipientIds(payload: any): Promise<string[]> {
  const table = String(payload?.table || "");
  const record = payload?.record || {};
  const sender = String(record.sender_user_id || "");
  const ids: string[] = [];

  if (table === "private_chat_messages") {
    const { data, error } = await admin.from("profiles").select("user_id").in("role", ["admin", "father"]);
    if (error) throw error;
    for (const row of data || []) if (String(row.user_id) !== sender) ids.push(String(row.user_id));
    return ids;
  }

  if (table === "developer_messages") {
    if (String(record.sender_side || "").toLowerCase() === "client") {
      const { data, error } = await admin.from("profiles").select("user_id").in("role", ["admin", "father"]);
      if (error) throw error;
      for (const row of data || []) if (String(row.user_id) !== sender) ids.push(String(row.user_id));
      return ids;
    }

    if (record.conversation_id) {
      const { data, error } = await admin.from("developer_conversations").select("client_user_id").eq("id", record.conversation_id).maybeSingle();
      if (error) throw error;
      if (data?.client_user_id) ids.push(String(data.client_user_id));
    }
  }

  return ids;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!authorized(req)) return new Response("Unauthorized", { status: 401 });
  if (!vapidPrivateKey) return Response.json({ ok: false, error: "VAPID_PRIVATE_KEY is not configured" }, { status: 500 });

  try {
    const payload = await req.json();
    const record = payload?.record || {};
    const ids = [...new Set(await recipientIds(payload))];
    if (!ids.length) return Response.json({ ok: true, sent: 0 });

    const { data: subscriptions, error } = await admin
      .from("push_subscriptions")
      .select("id,user_id,endpoint,p256dh,auth")
      .in("user_id", ids);
    if (error) throw error;

    const title = payload?.table === "private_chat_messages"
      ? "💬 Личный чат"
      : "💬 Новое сообщение в СТОGarage";
    const senderName = String(record.sender_side || "").toLowerCase() === "client" ? "Клиент" : "СТОGarage";
    const body = String(record.body || "Новое сообщение").slice(0, 300);

    let sent = 0, removed = 0;
    for (const sub of subscriptions || []) {
      try {
        await sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
          JSON.stringify({ title, body: senderName + ": " + body, url: "./", tag: "stogarage-chat" }),
          {
            vapidDetails: { subject: VAPID_SUBJECT, publicKey: VAPID_PUBLIC_KEY, privateKey: vapidPrivateKey },
            TTL: 3600,
            urgency: "high"
          }
        );
        sent++;
      } catch (error) {
        const status = Number(error?.statusCode || 0);
        if (status === 404 || status === 410) {
          await admin.from("push_subscriptions").delete().eq("id", sub.id);
          removed++;
        } else console.error("Push delivery failed:", status, error?.message || error);
      }
    }

    return Response.json({ ok: true, recipients: ids.length, subscriptions: (subscriptions || []).length, sent, removed });
  } catch (error) {
    console.error("Push webhook error:", error);
    return Response.json({ ok: false, error: error?.message || String(error) }, { status: 500 });
  }
});
