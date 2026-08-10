import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { setHasData, logEvent } from "../lib/state.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });
  await setHasData(username, false);
  await logEvent("data_wiped", { username });
  return res.status(200).json({ ok: true });
}
