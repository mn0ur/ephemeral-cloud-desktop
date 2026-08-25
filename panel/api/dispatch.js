import { sessionFromRequest } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession, setHasData, hasSavedData, logEvent,
} from "../lib/state.js";
import { dispatch, WORKFLOWS, tokenConfigured } from "../lib/github.js";
import { activeCount, MAX_CONCURRENT } from "../lib/desktops.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });

  const action = req.body?.action;
  const workflow = WORKFLOWS[action];
  if (!workflow) return res.status(400).json({ error: "unknown action" });

  // The username is NEVER taken from the request body for the caller's own
  // actions - always from their verified session, so nobody can start or
  // destroy a desktop under someone else's name.
  const session = await sessionFromRequest(req);
  if (!session) return res.status(401).json({ error: "sign in first" });
  const me = session.user_id;

  const sessions = await loadSessions();
  const live = ["pending", "ready", "active"];

  if (action === "start") {
    // Fail BEFORE recording anything. Marking a session pending and only then
    // discovering the dispatch cannot work is what left users watching
    // "Starting..." for a full timeout with no error and no way to retry.
    if (!tokenConfigured) {
      return res.status(503).json({
        error: "this deployment has no GitHub token, so it cannot start desktops yet",
      });
    }
    if (live.includes(sessions[me]?.status)) {
      return res.status(409).json({ error: "you already have a desktop running" });
    }
    if (activeCount(sessions) >= MAX_CONCURRENT) {
      // Deliberately generic - the exact ceiling is not something a user needs
      // to know, only that now is not the moment.
      return res.status(503).json({ error: "all desktops are busy right now - try again shortly" });
    }

    const persist = Boolean(req.body?.persist);
    await putSession(me, {
      status: "pending",
      email: session.email,
      dispatched_at: Date.now() / 1000,
    });
    await logEvent("login_start", { username: me, email: session.email, persist });

    try {
      await dispatch(workflow, {
        username: me,
        fresh: "false",
        guest_username: me,
        owner_email: session.email,
        persist: persist ? "true" : "false",
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
    if (persist) await setHasData(me, true);
    return res.status(202).json({ ok: true });
  }

  if (action === "destroy") {
    // A non-admin naming someone else gets a clear 403, not a silent redirect
    // onto their own session - which would destroy the caller's desktop with no
    // indication why.
    const target = req.body?.username || me;
    if (target !== me && !session.is_admin) {
      return res.status(403).json({ error: "not your session" });
    }
    if (!sessions[target]) return res.status(404).json({ error: "no such session" });
    try {
      await dispatch(workflow, { confirm: "DESTROY", guest_username: target });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message });
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
