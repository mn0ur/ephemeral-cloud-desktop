import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, putSession, logEvent } from "../lib/state.js";

// Called by desktop-up.yml once terraform apply succeeds. This deployment holds
// no AWS or Terraform credentials by design, so it cannot read `terraform
// output` itself - the guest's URL and password have to be handed to it here.
export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });

  const prior = (await loadSessions())[username] || {};
  // Prefer the email recorded at dispatch, which came from a verified Google
  // session and so cannot be spoofed by this callback. Fall back to the
  // callback's value only when there is no prior state - a redeploy mid-run, or
  // a desktop recovered after a partial failure - where losing the owner would
  // leave a desktop nobody can destroy from the panel.
  const email = prior.email || req.body?.owner_email || null;

  await putSession(username, {
    status: "ready", // the page polls /healthz before calling it active
    email,
    url: req.body?.url || null,
    password: req.body?.password || null,
    started_at: Date.now() / 1000,
  });
  await logEvent("start", { username, email, url: req.body?.url });
  return res.status(200).json({ ok: true });
}
