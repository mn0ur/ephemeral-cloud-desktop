import { sessionFromRequest } from "../../lib/auth.js";
import {
  addAdmin, removeAdmin, addPermanentUser, removePermanentUser,
} from "../../lib/state.js";

const ACTIONS = {
  admins: { add: addAdmin, remove: removeAdmin },
  permanent_users: { add: addPermanentUser, remove: removePermanentUser },
};

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const session = await sessionFromRequest(req);
  if (!session?.is_admin) return res.status(403).json({ error: "admin only" });

  const { list, action, email } = req.body || {};
  const fn = ACTIONS[list]?.[action];
  if (!fn) return res.status(400).json({ error: "unknown list or action" });
  if (!email || !email.includes("@")) return res.status(400).json({ error: "bad email" });

  const result = await fn(email);
  if (result?.ok === false) return res.status(400).json(result);
  return res.status(200).json({ ok: true });
}
