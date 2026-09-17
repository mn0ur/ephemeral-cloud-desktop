import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, dropSession, dropMachine, logEvent } from "../lib/state.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });

  const prior = (await loadSessions())[username] || {};
  const duration_s = prior.started_at
    ? Math.round(Date.now() / 1000 - prior.started_at)
    : null;

  await dropSession(username);
  // A DELETE is the only thing that removes a machine. Sleep keeps the record:
  // that is exactly what makes the next start a ~1 minute wake.
  const os = req.body?.os || prior.os || "linux";
  await dropMachine(username, os);
  await logEvent("destroy", {
    username,
    email: prior.email,
    duration_s,
    reason: req.body?.reason || "manual",
  });
  return res.status(200).json({ ok: true });
}
