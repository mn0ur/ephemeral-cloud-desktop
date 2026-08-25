import { sessionFromRequest, GOOGLE_CLIENT_ID } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession, hasSavedData, stateConfigured,
} from "../lib/state.js";
import { runProgress, tokenConfigured } from "../lib/github.js";
import {
  refreshOwn, activeCount, MAX_CONCURRENT, HOURLY_USD, DESKTOP_DOMAIN,
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

  const mine = session ? sessions[session.user_id] || null : null;
  const watching = ["pending", "ready"];
  const worthProgress =
    session &&
    (watching.includes(mine?.status) ||
      (session.is_admin && Object.values(sessions).some((s) => watching.includes(s.status))));

  const out = {
    google_client_id: GOOGLE_CLIENT_ID,
    session,
    my_session: mine,
    sessions: visible,
    active_count: activeCount(sessions),
    max_concurrent: session?.is_admin ? MAX_CONCURRENT : null,
    desktop_domain: DESKTOP_DOMAIN,
    hourly_usd: HOURLY_USD,
    // Two GitHub API calls - only when something is actually mid-flight. A
    // settled panel has nothing to report, and polling the Actions API every
    // few seconds forever would burn rate limit for no reason.
    progress: worthProgress ? await runProgress() : null,
    has_saved_data: session ? await hasSavedData(session.user_id) : false,
  };

  if (!tokenConfigured) {
    out.error =
      "No GH_TOKEN set on this deployment. Buttons are inert until it is added in Vercel > Settings > Environment Variables.";
  }

  return res.status(200).json(out);
}
