import { sessionFromRequest, GOOGLE_CLIENT_ID } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession, hasSavedData, stateConfigured,
} from "../lib/state.js";
import { runProgress, tokenConfigured } from "../lib/github.js";
import {
  refreshOwn, activeCount, MAX_CONCURRENT, HOURLY_USD, HOURLY_USD_WINDOWS, DESKTOP_DOMAIN, REGIONS,
  sessionPhase, canCancel,
} from "../lib/desktops.js";

export default async function handler(req, res) {
  // Never cached: the page polls this to decide what to render, and a cached
  // response would show a desktop as running after it was destroyed.
  res.setHeader("Cache-Control", "no-store");

  if (!stateConfigured) {
    return res.status(200).json({
      error:
        "No KV store attached to this project. Create one in Vercel > Storage and connect it, then redeploy.",
      google_client_id: GOOGLE_CLIENT_ID,
      session: null,
      sessions: {},
    });
  }

  const session = await sessionFromRequest(req);
  let sessions = await loadSessions();

  if (session) {
    sessions = await refreshOwn(sessions, session.user_id, putSession, dropSession);
  }

  // Non-admins see only their own session. Never anyone else's email, URL or
  // password - the admin view is the only place those appear.
  const visible = {};
  for (const [uname, s] of Object.entries(sessions)) {
    const mine = session && session.user_id === uname;
    if (session && (mine || session.is_admin)) visible[uname] = { ...s };
  }

  // The page renders from `phase` - never from raw status - so a start that
  // has not produced a machine yet can never be drawn as an existing one.
  const own = session ? sessions[session.user_id] || null : null;
  const phase = sessionPhase(own);
  const mine = own ? { ...own, phase, can_cancel: canCancel(own) } : null;
  // Progress is the caller's OWN run for the action in flight, anchored on
  // when that action was dispatched; nobody else's run is ever shown here.
  const worthProgress = Boolean(session) && ["starting", "booting", "destroying"].includes(phase);
  const anchor = phase === "destroying" ? own?.destroy_dispatched_at : own?.dispatched_at;

  const out = {
    google_client_id: GOOGLE_CLIENT_ID,
    session,
    my_session: mine,
    sessions: visible,
    active_count: activeCount(sessions),
    max_concurrent: session?.is_admin ? MAX_CONCURRENT : null,
    desktop_domain: DESKTOP_DOMAIN,
    hourly_usd: HOURLY_USD,
    hourly_usd_windows: HOURLY_USD_WINDOWS,
    regions: REGIONS,
    // Two GitHub API calls - only when something is actually mid-flight. A
    // settled panel has nothing to report, and polling the Actions API every
    // few seconds forever would burn rate limit for no reason.
    progress: worthProgress ? await runProgress(session.user_id, anchor) : null,
    has_saved_data: session ? await hasSavedData(session.user_id) : false,
  };

  if (!tokenConfigured) {
    out.error =
      "No GH_TOKEN set on this deployment. Buttons are inert until it is added in Vercel > Settings > Environment Variables.";
  }

  return res.status(200).json(out);
}
