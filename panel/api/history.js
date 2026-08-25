import { sessionFromRequest } from "../lib/auth.js";
import { readHistory } from "../lib/state.js";

export default async function handler(req, res) {
  const session = await sessionFromRequest(req);
  if (!session?.is_admin) return res.status(403).json({ error: "admin only" });
  return res.status(200).json({ events: await readHistory(500) });
}
