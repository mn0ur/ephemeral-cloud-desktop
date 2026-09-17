import { sessionFromRequest } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession, setHasData, hasSavedData, logEvent, clearNotice,
  loadMachines, putMachine, claimOnce, releaseClaim,
} from "../lib/state.js";
import { dispatch, WORKFLOWS, tokenConfigured } from "../lib/github.js";
import {
  activeCount, MAX_CONCURRENT, requestedOs, requestedRegion, startRefusalReason, NO_ACCESS_MESSAGE,
} from "../lib/desktops.js";
import { startPlan, machineKey, wipeRefusalReason, deleteOs, staleBuild } from "../lib/machines.js";

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

    // Read-plan-dispatch is NOT atomic on its own: loadMachines, startPlan
    // and the dispatch below all happen across separate round trips, so two
    // Starts within the same window (a double-click, two tabs, one tab per
    // OS) can both read the same stale machine state, both pass every check
    // above, and both dispatch a real workflow - two billable EC2 machines
    // with only one session hash between them, the loser silently clobbered.
    // A short per-user claim closes that window: it only needs to outlive
    // this handler's own work (well under a minute), not the minutes-long
    // build or the 40-60s wake that follow it - those are already guarded
    // once the session status itself becomes "building"/"waking" (see
    // LIVE_STATUSES in lib/desktops.js and startRefusalReason above, which
    // reject every subsequent request while that status holds).
    const startClaim = `start:${me}`;
    if (!(await claimOnce(startClaim, 90))) {
      return res.status(409).json({ error: "a start is already in progress for your account" });
    }

    try {
      const machines = await loadMachines();
      const plan = startPlan(machines, me, os);

      // Only one machine per user runs at a time. Sleep the other one first
      // and remember what to wake when it reports back (api/session-slept
      // dispatches the wake), so the two workflows never have to coordinate
      // with each other.
      if (plan.sleepOs) {
        try {
          await dispatch(WORKFLOWS.sleep, { guest_username: me, os: plan.sleepOs });
        } catch (e) {
          // Nothing was written yet - the session for `me` still does not
          // exist, so there is nothing to roll back.
          return res.status(e.status || 500).json({ error: e.message });
        }
        // A switch is TWO machines: the one still running (plan.sleepOs) and
        // the one being brought up (os). Overwriting the session with only
        // the target OS discarded the running machine's identity - so if the
        // sleep failed it kept billing with nothing on screen, and a delete
        // in that window destroyed the WRONG machine (it read session.os,
        // which by then meant the target). Both are named explicitly now:
        // sleep_os is what is being stopped, wake_os what is being started,
        // and deleteOs() prefers sleep_os while the switch is in flight.
        //
        // The prior session's identity fields (url, instance_id, started_at,
        // lost_token_hash) are carried, but its two ACTION timestamps are
        // not: a stale destroy_dispatched_at or sleep_dispatched_at would
        // make sessionPhase draw this as "destroying"/"sleeping" instead of
        // the switch that is actually happening.
        const { destroy_dispatched_at: _d, sleep_dispatched_at: _s, ...carried } = sessions[me] || {};
        await putSession(me, {
          ...carried,
          status: "waking", email: session.email, dispatched_at: Date.now() / 1000,
          os, region, pending_wake: true,
          sleep_os: plan.sleepOs, wake_os: os,
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
        //
        // "Already building" needs one thing written first, though. The
        // sign-in build (api/status.js) writes a MACHINE record and no
        // session at all, so a user who presses Start during that build used
        // to land here with nothing written: the page's busy overlay only
        // clears once my_session exists, so it never cleared, and because no
        // session ever carried start_requested, session-ready parked the very
        // machine the user was sitting there waiting for. Write the session
        // the sign-in build never wrote - honest "building" phase, anchored
        // on when the build actually started, flagged as asked-for.
        const adopted = machines[machineKey(me, os)];
        if (adopted?.state === "building" && !staleBuild(adopted)) {
          await putSession(me, {
            status: "building",
            email: session.email,
            dispatched_at: adopted.building_since || adopted.created_at || Date.now() / 1000,
            os,
            region,
            start_requested: true,
          });
        }
        return res.status(202).json({ ok: true, action: "adopt" });
      }

      // plan.action === "build": no machine record exists yet.
      await putSession(me, {
        status: "building",
        email: session.email,
        dispatched_at: Date.now() / 1000,
        os,
        region,
        // The user just pressed Start - session-ready must not mistake this
        // for the sign-in build in api/status.js and park it the moment it
        // comes up.
        start_requested: true,
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
    } finally {
      // Released on every path - success, refusal, or dispatch failure - so
      // a crash mid-handler cannot lock the user out past the TTL, and a
      // legitimate next Start (once the session itself reflects the result)
      // is never blocked by a stale claim.
      await releaseClaim(startClaim);
    }
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
    // A PARKED machine has no session at all - that is the whole point of
    // sleeping. Guarding this path on the session alone therefore made a
    // parked machine undeletable: it kept costing its disk (~$4/month
    // Windows, ~$2.50 Linux) forever with no way to remove it. The machine
    // record is the second source of truth, and either one is enough.
    const existingSession = sessions[target] || null;
    const machines = await loadMachines();
    // Body first (that is how the Start card names a parked machine), then
    // the session - sleep_os while an OS switch is in flight, so a delete
    // then targets the machine still running rather than the one being
    // switched to. See deleteOs() in lib/machines.js.
    // The || "linux" is only for a legacy session that recorded no os at all;
    // with no session AND no body os, `os` stays null, no machine can be
    // looked up, and the 404 below answers.
    const os = deleteOs(existingSession, req.body?.os) || (existingSession ? "linux" : null);
    const existing = os ? machines[machineKey(target, os)] : null;
    const liveMachine = Boolean(existing) && existing.state !== "deleted";
    if (!existingSession && !liveMachine) {
      return res.status(404).json({ error: "no such machine" });
    }
    const region = existingSession?.region || existing?.region || "ap-south-1";
    try {
      await dispatch(workflow, {
        confirm: "DESTROY",
        guest_username: target,
        os,
        region,
      });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message });
    }
    // Anchor for the panel's destroy progress bar. Kept on the session so a
    // reload mid-destroy still shows how far along it is; the whole entry is
    // dropped by session-ended when the workflow finishes. A parked machine
    // has no session yet, so one is written here purely to carry that anchor
    // - it has no live status, so it occupies no MAX_CONCURRENT slot.
    await putSession(target, {
      ...(existingSession || {}),
      email: existingSession?.email || (target === me ? session.email : null),
      os,
      region,
      destroy_dispatched_at: Date.now() / 1000,
    });
    // A DELETE is the only action that removes the machine record - a sleep
    // keeps it, which is what makes the next start a wake instead of a build.
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
    // The volume cannot be deleted while attached, and deleting it under a
    // live desktop would corrupt whatever is mid-write. Refuse here with a
    // reason rather than letting the workflow fail minutes later. Checks
    // both the session AND the machine record - see wipeRefusalReason's own
    // comment for why either alone is not enough (a sleeping machine has NO
    // session record at all, and a session can be live before any machine
    // record exists).
    const targetMachines = await loadMachines();
    const wipeRefusal = wipeRefusalReason(targetMachines, sessions, target);
    if (wipeRefusal) {
      return res.status(409).json({ error: wipeRefusal });
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
