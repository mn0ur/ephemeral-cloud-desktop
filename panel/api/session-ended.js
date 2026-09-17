import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadSessions, dropSession, putMachine, logEvent } from "../lib/state.js";
import { MACHINE_OSES } from "../lib/machines.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });

  const prior = (await loadSessions())[username] || {};

  // Which machine was destroyed decides which record gets the tombstone, so a
  // wrong answer here tombstones the machine that is still there and leaves
  // the destroyed one looking alive. Silently defaulting to "linux" did
  // exactly that for any caller that forgot the field; there is no safe
  // guess, so an unnameable OS is a 400 - checked BEFORE anything is written.
  const os = req.body?.os || prior.os;
  if (!MACHINE_OSES.includes(os)) {
    return res.status(400).json({ error: "os is required (linux or windows)" });
  }

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
  await putMachine(username, os, { os, state: "deleted", deleted_at: Date.now() / 1000 });
  await logEvent("destroy", {
    username,
    email: prior.email,
    duration_s,
    reason: req.body?.reason || "manual",
  });
  return res.status(200).json({ ok: true });
}
