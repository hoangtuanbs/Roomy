// Cloudflare Pages Function: POST /api/contact
// Receives the website's contact form and forwards it to Formspree, which emails it on.
// The destination address lives only in the Formspree account, never in the page or this repo.
// Setup: create a form at formspree.io, then add its ID (the part after /f/) as the
// FORMSPREE_FORM_ID environment variable in Cloudflare Pages › Settings › Variables and Secrets.

const TOPICS = ["Question", "Idea", "Problem", "Other"];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function reply(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export async function onRequestPost({ request, env }) {
  let data;
  try {
    const type = request.headers.get("content-type") || "";
    data = type.includes("application/json") ? await request.json() : Object.fromEntries(await request.formData());
  } catch {
    return reply({ ok: false, error: "The form couldn't be read. Please try again." }, 400);
  }

  // Bots fill the hidden "website" field; pretend it worked and drop it.
  if (String(data.website || "").trim()) return reply({ ok: true });

  const name = String(data.name || "").trim().slice(0, 100);
  const email = String(data.email || "").trim().slice(0, 200);
  const message = String(data.message || "").trim().slice(0, 5000);
  const topic = TOPICS.includes(data.topic) ? data.topic : "Other";

  if (!EMAIL_RE.test(email)) return reply({ ok: false, field: "email", error: "Please enter an email address we can reply to." }, 400);
  if (message.length < 10) return reply({ ok: false, field: "message", error: "Please write a few more words." }, 400);

  if (!env.FORMSPREE_FORM_ID) {
    return reply({ ok: false, error: "The contact form isn't connected yet. Please open an issue on GitHub instead." }, 503);
  }

  const res = await fetch(`https://formspree.io/f/${encodeURIComponent(env.FORMSPREE_FORM_ID)}`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      name: name || "(no name)",
      email,
      topic,
      message,
      _replyto: email,
      _subject: `RoomyDisk website: ${topic}${name ? " from " + name : ""}`,
    }),
  });

  if (!res.ok) return reply({ ok: false, error: "Your message couldn't be sent just now. Please try again in a minute." }, 502);
  return reply({ ok: true });
}

export function onRequest() {
  return new Response("Use POST.", { status: 405, headers: { allow: "POST" } });
}
