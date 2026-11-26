// Cloudflare Pages Function: POST /api/contact
// Receives the website's contact form and emails it to you through Resend (resend.com).
// Your address lives only in Cloudflare's encrypted settings, never in the page or this repo.
//
// Settings › Variables and Secrets in Cloudflare Pages:
//   RESEND_API_KEY  (secret)  API key from resend.com › API Keys, "Sending access" is enough.
//   CONTACT_TO      (secret)  Where messages go. Without a verified domain in Resend this must be
//                             the address you signed up to Resend with.
//   CONTACT_FROM    (optional) Sender, e.g. "RoomyDisk <hello@yourdomain>" once a domain is verified.
//                             Defaults to Resend's shared test sender.
//   TURNSTILE_SECRET (optional) Cloudflare Turnstile secret, if you turn on the bot check (see README).

const TOPICS = ["Question", "Idea", "Problem", "Other"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function reply(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function esc(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

export async function onRequestPost({ request, env }) {
  let data;
  try {
    const type = request.headers.get("content-type") || "";
    data = type.includes("application/json") ? await request.json() : Object.fromEntries(await request.formData());
  } catch {
    return reply({ ok: false, error: "The form couldn't be read. Please try again." }, 400);
  }

  // Bots fill the hidden "website" field or submit within a second of the page loading.
  // Pretend it worked and drop it.
  const elapsed = Date.now() - Number(data.started || 0);
  if (String(data.website || "").trim() || (data.started && elapsed < 2500)) return reply({ ok: true });

  const name = String(data.name || "").trim().slice(0, 100);
  const email = String(data.email || "").trim().slice(0, 200);
  const message = String(data.message || "").trim().slice(0, 5000);
  const topic = TOPICS.includes(data.topic) ? data.topic : "Other";

  if (!EMAIL_RE.test(email)) return reply({ ok: false, field: "email", error: "Please enter an email address we can reply to." }, 400);
  if (message.length < 10) return reply({ ok: false, field: "message", error: "Please write a few more words." }, 400);

  if (env.TURNSTILE_SECRET) {
    const check = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      body: new URLSearchParams({
        secret: env.TURNSTILE_SECRET,
        response: String(data["cf-turnstile-response"] || ""),
        remoteip: request.headers.get("CF-Connecting-IP") || "",
      }),
    }).then((r) => r.json()).catch(() => ({ success: false }));
    if (!check.success) return reply({ ok: false, error: "The bot check didn't pass. Please reload the page and try again." }, 400);
  }

  if (!env.RESEND_API_KEY || !env.CONTACT_TO) {
    return reply({ ok: false, error: "The contact form isn't connected yet. Please open an issue on GitHub instead." }, 503);
  }

  const subject = `RoomyDisk website: ${topic}${name ? " from " + name : ""}`;
  const text = `${message}\n\n--\nFrom: ${name || "(no name)"} <${email}>\nTopic: ${topic}\nSent from the RoomyDisk website. Reply to this email to answer.`;
  const html =
    `<div style="font:15px/1.55 -apple-system,Segoe UI,sans-serif;color:#111">` +
    `<p style="white-space:pre-wrap;margin:0 0 20px">${esc(message)}</p>` +
    `<p style="color:#666;font-size:13px;border-top:1px solid #ddd;padding-top:12px;margin:0">` +
    `From ${esc(name || "(no name)")} &lt;${esc(email)}&gt; · Topic: ${esc(topic)}<br>Sent from the RoomyDisk website. Reply to this email to answer.</p></div>`;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json" },
    body: JSON.stringify({
      from: env.CONTACT_FROM || "RoomyDisk website <onboarding@resend.dev>",
      to: [env.CONTACT_TO],
      reply_to: email,
      subject,
      text,
      html,
    }),
  });

  if (res.status === 429) return reply({ ok: false, error: "Lots of messages today. Please try again tomorrow." }, 503);
  if (!res.ok) return reply({ ok: false, error: "Your message couldn't be sent just now. Please try again in a minute." }, 502);
  return reply({ ok: true });
}

export function onRequest() {
  return new Response("Use POST.", { status: 405, headers: { allow: "POST" } });
}
