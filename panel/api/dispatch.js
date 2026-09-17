import { sessionFromRequest } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession, setHasData, hasSavedData, logEvent, clearNotice,
  loadMachines, putMachine,
} from "../lib/state.js";
import { dispatch, WORKFLOWS, tokenConfigured } from "../lib/github.js";
import {
  activeCount, MAX_CONCURRENT, requestedOs, requestedRegion, startRefusalReason, NO_ACCESS_MESSAGE,
  LIVE_STATUSES,
} from "../lib/desktops.js";
import { startPlan, machineKey, MACHINE_OSES } from "../lib/machines.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });

  // "destroy" is kept as an action name only so a cached old page - which
  // still POSTs {action: "destroy"} - keeps working; "delete" is the name
  // everywhere else (the panel, the docs, the machine-record bookkeeping
  // below). Both resolve to the same desktop-down.yml workflow.
  const rawAction = req.body?.action;
  const action = rawAction === "destroy" ? "delete" : rawAction;
  const workflow = action === "delete" ? WORKFLOWS.destroy : WORKFLOWS[action];
  if (!workflow) return res.status(400).json({ error: "unknown action" });

  // The username is NEVER taken from the request body for the caller's own
  // actions - always from their verified session, so nobody can start or
  // destroy a desktop under someone else's name.
  const session = await sessionFromRequest(req);
  if (!session) return res.status(401).json({ error: "sign in first" });
  const me = session.user_id;

  const sessions = await loadSessions();
  const live = LIVE_STATUSES;

  if (action === "start") {
    // Fail BEFORE recording anything. Marking a session pending and only then
    // discovering the dispatch cannot work is what left users watching
    // "Starting..." for a full timeout with no error and no way to retry.
    if (!tokenConfigured) {
      return res.status(503).json({
        error: "this deployment has no GitHub token, so it cannot start desktops yet",
      });
    }
    const refusal = startRefusalReason(session, sessions[me]);
    if (refusal) {
      return res.status(refusal === NO_ACCESS_MESSAGE ? 403 : 409).json({ error: refusal });
    }
    if (activeCount(sessions) >= MAX_CONCURRENT) {
      // Deliberately generic - the exact ceiling is not something a user needs
      // to know, only that now is not the moment.
      return res.status(503).json({ error: "all desktops are busy right now - try again shortly" });
    }

    // Every tier chooses Linux or Windows at Start (see requestedOs).
    const os = requestedOs(req.body?.os);
    // Same shape as os: server is the actual enforcement point, the selector
    // on the client is only a hint. One region only - see requestedRegion.
    const region = requestedRegion(req.body?.region);

    const machines = await loadMachines();
    const plan = startPlan(machines, me, os);

    // Only one machine per user runs at a time. Sleep the other one first and
    // remember what to wake when it reports back (api/session-slept dispatches
    // the wake), so the two workflows never have to coordinate with each other.
    if (plan.sleepOs) {
      try {
        await dispatch(WORKFLOWS.sleep, { guest_username: me, os: plan.sleepOs });
      } catch (e) {
        // Nothing was written yet - the session for `me` still does not
        // exist, so there is nothing to roll back.
        return res.status(e.status || 500).json({ error: e.message });
      }
      await putSession(me, {
        status: "waking", email: session.email, dispatched_at: Date.now() / 1000,
        os, region, pending_wake: true,
      });
      return res.status(202).json({ ok: true, waiting_for: plan.sleepOs });
    }

    if (plan.action === "wake") {
      await putSession(me, {
        status: "waking", email: session.email, dispatched_at: Date.now() / 1000, os, region,
      });
      try {
        await dispatch(WORKFLOWS.wake, { guest_username: me, os });
      } catch (e) {
        await dropSession(me);
        return res.status(e.status || 500).json({ error: e.message });
      }
      return res.status(202).json({ ok: true, action: "wake" });
    }

    if (plan.action === "adopt") {
      // Already building or running - the page just needs to keep polling.
      return res.status(202).json({ ok: true, action: "adopt" });
    }

    // plan.action === "build": no machine record exists yet.
    await putSession(me, {
      status: "building",
      email: session.email,
      dispatched_at: Date.now() / 1000,
      os,
      region,
    });
    await logEvent("login_start", { username: me, email: session.email, persist: true, os, region });

    try {
      await dispatch(workflow, {
        username: me,
        fresh: "false",
        guest_username: me,
        owner_email: session.email,
        // Everyone who can start is a permanent user: files are always kept.
        persist: "true",
        is_guest: "false",
        os,
        region,
        use_spot: "false",
      });
    } catch (e) {
      // Roll back on ANY dispatch failure - a GitHub outage, a revoked token or
      // a rate limit would otherwise wedge the session in "pending" and hold one
      // of MAX_CONCURRENT until it aged out.
      await dropSession(me);
      await logEvent("start_failed", { username: me, email: session.email });
      return res.status(e.status || 500).json({ error: e.message });
    }

    // Only after a successful dispatch: claiming data exists when the start
    // never ran would show a delete button for nothing.
    await setHasData(me, true);
    await clearNotice(me);
    return res.status(202).json({ ok: true });
  }

  if (action === "sleep") {
    // Ends the SESSION (the user is done for now) without touching the
    // machine record - that is exactly what makes the next Start a wake
    // instead of a build. A non-admin naming someone else gets a clear 403.
    const target = req.body?.username || me;
    if (target !== me && !session.is_admin) return res.status(403).json({ error: "not your session" });
    if (!sessions[target]) return res.status(404).json({ error: "no such session" });
    const os = sessions[target].os || "linux";
    try {
      await dispatch(WORKFLOWS.sleep, { guest_username: target, os });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message });
    }
    await putSession(target, { ...sessions[target], sleep_dispatched_at: Date.now() / 1000 });
    return res.status(202).json({ ok: true });
  }

  if (action === "delete") {
    // A non-admin naming someone else gets a clear 403, not a silent redirect
    // onto their own session - which would delete the caller's desktop with no
    // indication why.
    const target = req.body?.username || me;
    if (target !== me && !session.is_admin) {
      return res.status(403).json({ error: "not your session" });
    }
    if (!sessions[target]) return res.status(404).json({ error: "no such session" });
    const os = sessions[target]?.os || "linux";
    try {
      await dispatch(workflow, {
        confirm: "DESTROY",
        guest_username: target,
        os,
        region: sessions[target]?.region || "ap-south-1",
      });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message });
    }
    // Anchor for the panel's destroy progress bar. Kept on the session so a
    // reload mid-destroy still shows how far along it is; the whole entry is
    // dropped by session-ended when the workflow finishes.
    await putSession(target, { ...sessions[target], destroy_dispatched_at: Date.now() / 1000 });
    // A DELETE is the only action that removes the machine record - a sleep
    // keeps it, which is what makes the next start a wake instead of a build.
    const machines = await loadMachines();
    const existing = machines[machineKey(target, os)];
    if (existing) {
      await putMachine(target, os, { ...existing, state: "deleting" });
    }
    return res.status(202).json({ ok: true });
  }

  if (action === "wipe") {
    const target = req.body?.username || me;
    if (target !== me && !session.is_admin) {
      return res.status(403).json({ error: "not your data" });
    }
    if (!(await hasSavedData(target))) {
      return res.status(404).json({ error: "no saved data to delete" });
    }
    // The volume cannot be deleted while attached, and deleting it under a live
    // desktop would corrupt whatever is mid-write. Refuse here with a reason
    // rather than letting the workflow fail minutes later.
    if (live.includes(sessions[target]?.status)) {
      return res.status(409).json({
        error: "that desktop is running - destroy it first, then delete the data",
      });
    }
    // A sleeping machine has NO session record at all - the check above would
    // miss it, and would have let a wipe through while a stopped machine's
    // volume is still attached. The wipe workflow now detaches from a stopped
    // machine and deletes, so that is no longer unsafe, but a still-running or
    // still-building machine has no session gap to close: refuse here too, and
    // tell the user the truth instead of letting the workflow fail later.
    const targetMachines = await loadMachines();
    const liveMachine = MACHINE_OSES.some((os) =>
      ["running", "building"].includes(targetMachines[machineKey(target, os)]?.state)
    );
    if (liveMachine) {
      return res.status(409).json({
        error: "that desktop is running or still building - destroy it first, then delete the data",
      });
    }
    await logEvent("wipe_requested", { username: target, by: me });
    try {
      await dispatch(workflow, { guest_username: target, confirm: "DELETE" });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message });
    }
    return res.status(202).json({ ok: true });
  }

  return res.status(400).json({ error: "unknown action" });
}
