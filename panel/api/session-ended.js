import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, dropSession, putMachine, logEvent } from "../lib/state.js";

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
  // A DELETE is the only thing that removes a machine. Sleep keeps the record
  // as-is (state: "sleeping"); a delete keeps a TOMBSTONE instead of erasing
  // the record outright - missingOses() cannot otherwise tell "never built"
  // from "deliberately deleted", and without this a delete would just get
  // silently rebuilt by the very next /api/status poll's sign-in-build pass
  // (real money, against explicit user intent). No instance_id/hostname
  // carried over - the machine is actually gone.
  const os = req.body?.os || prior.os || "linux";
  await putMachine(username, os, { os, state: "deleted", deleted_at: Date.now() / 1000 });
  await logEvent("destroy", {
    username,
    email: prior.email,
    duration_s,
    reason: req.body?.reason || "manual",
  });
  return res.status(200).json({ ok: true });
}
