import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, putSession, logEvent, clearHealth, loadMachines, putMachine } from "../lib/state.js";
import { REGIONS, hashToken } from "../lib/desktops.js";
import { machineKey } from "../lib/machines.js";
import { dispatch, WORKFLOWS } from "../lib/github.js";

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
    password: req.body?.password || prior.password || null,
    login_user: req.body?.login_user || prior.login_user || null,
    started_at: startedAt,
    os,
    region,
    // What was actually launched: Linux falls back to on-demand when spot has
    // no capacity, Windows is always on-demand. Drives the cost shown.
    market: os === "windows" || req.body?.market === "on-demand" ? "on-demand" : "spot",
    instance_id: req.body?.instance_id || null,
    // Lets this machine report its own spot reclaim (api/session-lost.js).
    // Hashed: the raw token only ever exists on the machine.
    ...(req.body?.session_token ? { lost_token_hash: hashToken(req.body.session_token) } : {}),
    // Cancelled while starting: the destroy waits behind this run in the
    // per-user concurrency group. Keep the mark so the page shows "Shutting
    // down" instead of offering Open on a machine that is about to go.
    ...(prior.destroy_dispatched_at ? { destroy_dispatched_at: prior.destroy_dispatched_at } : {}),
  });
  await clearHealth(username);

  // The machine outlives the session (Plan B). Recording it here - the one
  // place that already knows a machine exists and answers - keeps the registry
  // true for both a fresh build and a wake.
  const machines = await loadMachines();
  const priorMachine = machines[machineKey(username, os)] || {};
  await putMachine(username, os, {
    ...priorMachine,
    os,
    state: "running",
    instance_id: req.body?.instance_id || priorMachine.instance_id || null,
    hostname: (req.body?.url || "").replace(/^https?:\/\//, "") || priorMachine.hostname || null,
    created_at: priorMachine.created_at || Date.now() / 1000,
    last_woken_at: Date.now() / 1000,
    ...(req.body?.session_token ? { lost_token_hash: hashToken(req.body.session_token) } : {}),
  });

  // Built but not asked for: park it, so the user pays disk and not
  // $0.36/hour for a machine they have not opened. This only fires for a
  // sign-in build (prior.status was "building" or there was no session at
  // all) that nobody flagged start_requested - a manual Start (dispatch.js)
  // and an OS-switch build (session-slept.js) both set that flag, so a
  // machine the user actually asked for stays running.
  if ((!prior.status || prior.status === "building") && !prior.start_requested) {
    try {
      await dispatch(WORKFLOWS.sleep, { guest_username: username, os });
      const latest = (await loadSessions())[username];
      if (latest) {
        await putSession(username, { ...latest, sleep_dispatched_at: Date.now() / 1000 });
      }
    } catch (e) {
      // Nothing to roll back: the machine stays running, and it'll just cost
      // an extra hour until someone notices or a future build succeeds in
      // parking it. Never fail this callback over it - the machine IS ready.
      console.error("park-after-build dispatch failed", os, e.message);
    }
  }

  await logEvent("start", { username, email, url: req.body?.url, os, region });
  return res.status(200).json({ ok: true });
}
