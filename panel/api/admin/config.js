import { sessionFromRequest, bearerOk, HUB_CALLBACK_SECRET } from "../../lib/auth.js";
import { getGuestLimitMinutes, setGuestLimitMinutes } from "../../lib/state.js";

export default async function handler(req, res) {
  if (req.method === "GET") {
    // Either an admin browsing the console, or the reaper workflow reading
    // the current limit before deciding what to destroy - the reaper has no
    // Google session, so it authenticates the same way the START/DESTROY
    // callbacks already do.
    const session = await sessionFromRequest(req);
    const viaCallback = bearerOk(req, HUB_CALLBACK_SECRET);
    if (!session?.is_admin && !viaCallback) {
      return res.status(403).json({ error: "admin only" });
    }
    return res.status(200).json({ guest_limit_minutes: await getGuestLimitMinutes() });
  }

  if (req.method === "POST") {
    const session = await sessionFromRequest(req);
    if (!session?.is_admin) return res.status(403).json({ error: "admin only" });
    const minutes = Number(req.body?.guest_limit_minutes);
    if (!Number.isFinite(minutes) || minutes <= 0) {
      return res.status(400).json({ error: "guest_limit_minutes must be a positive number" });
    }
    return res.status(200).json({ guest_limit_minutes: await setGuestLimitMinutes(minutes) });
  }

  return res.status(405).json({ error: "GET or POST only" });
}
