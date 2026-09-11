import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, putSession, logEvent, getGuestLimitMinutes } from "../lib/state.js";

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

  const launchedAt = Number(req.body?.launched_at);
  const startedAt = Number.isFinite(launchedAt) && launchedAt > 0 ? launchedAt : Date.now() / 1000;
  const isGuest = Boolean(prior.is_guest);
  // os was decided at dispatch from a verified session; the callback's value
  // is only a fallback for a session with no prior state (redeploy mid-run).
  const os = prior.os || (req.body?.os === "windows" ? "windows" : "linux");
  await putSession(username, {
    status: "ready", // the page polls the per-OS probe before calling it active
    email,
    url: req.body?.url || null,
    password: req.body?.password || null,
    login_user: req.body?.login_user || null,
    started_at: startedAt,
    is_guest: isGuest,
    os,
    ...(isGuest ? { expires_at: startedAt + (await getGuestLimitMinutes()) * 60 } : {}),
  });
  await logEvent("start", { username, email, url: req.body?.url, os });
  return res.status(200).json({ ok: true });
}
