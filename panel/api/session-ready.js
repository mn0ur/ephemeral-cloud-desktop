import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, putSession, logEvent, getGuestLimitMinutes, clearHealth } from "../lib/state.js";
import { REGIONS, hashToken } from "../lib/desktops.js";

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
  // region was decided at dispatch (now always ap-south-1); the callback's
  // value is only a fallback for a session with no prior state (redeploy
  // mid-run), same as os above.
  const region = prior.region || (REGIONS[req.body?.region] ? req.body.region : "ap-south-1");
  await putSession(username, {
    status: "ready", // the page polls the per-OS probe before calling it active
    email,
    url: req.body?.url || null,
    password: req.body?.password || null,
    login_user: req.body?.login_user || null,
    started_at: startedAt,
    is_guest: isGuest,
    os,
    region,
    // What was actually launched: Linux falls back to on-demand when spot has
    // no capacity, Windows is always on-demand. Drives the cost shown.
    market: os === "windows" || req.body?.market === "on-demand" ? "on-demand" : "spot",
    instance_id: req.body?.instance_id || null,
    // Lets this machine report its own spot reclaim (api/session-lost.js).
    // Hashed: the raw token only ever exists on the machine.
    ...(req.body?.session_token ? { lost_token_hash: hashToken(req.body.session_token) } : {}),
    ...(isGuest ? { expires_at: startedAt + (await getGuestLimitMinutes()) * 60 } : {}),
    // Cancelled while starting: the destroy waits behind this run in the
    // per-user concurrency group. Keep the mark so the page shows "Shutting
    // down" instead of offering Open on a machine that is about to go.
    ...(prior.destroy_dispatched_at ? { destroy_dispatched_at: prior.destroy_dispatched_at } : {}),
  });
  await clearHealth(username);
  await logEvent("start", { username, email, url: req.body?.url, os, region });
  return res.status(200).json({ ok: true });
}
