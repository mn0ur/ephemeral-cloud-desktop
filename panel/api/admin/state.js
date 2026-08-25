import { sessionFromRequest, GOOGLE_CLIENT_ID } from "../../lib/auth.js";
import {
  loadSessions, getAdmins, getPermanentUsers, getGuestLimitMinutes,
} from "../../lib/state.js";

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const session = await sessionFromRequest(req);

  if (!session) {
    return res.status(200).json({ google_client_id: GOOGLE_CLIENT_ID, session: null });
  }
  if (!session.is_admin) {
    return res.status(403).json({ error: "admin only" });
  }

  return res.status(200).json({
    google_client_id: GOOGLE_CLIENT_ID,
    session,
    sessions: await loadSessions(),
    admins: await getAdmins(),
    permanent_users: await getPermanentUsers(),
    guest_limit_minutes: await getGuestLimitMinutes(),
  });
}
