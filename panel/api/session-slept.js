import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadMachines, putMachine, dropSession, logEvent } from "../lib/state.js";
import { machineKey } from "../lib/machines.js";

// Called by desktop-sleep.yml once the machine is stopped. The machine RECORD
// survives - that is the difference between sleeping and being destroyed - but
// the session is over.
export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  const os = req.body?.os === "windows" ? "windows" : "linux";
  if (!username) return res.status(400).json({ error: "bad username" });

  const machines = await loadMachines();
  const prior = machines[machineKey(username, os)];
  if (prior) {
    await putMachine(username, os, { ...prior, state: "sleeping", slept_at: Date.now() / 1000 });
    await logEvent("slept", { username, os });
  } else {
    // The machine IS stopped (the workflow only calls this after a confirmed
    // stop) but there was no record to update - an out-of-band delete raced
    // this callback. Distinct event so the mismatch shows up in history
    // instead of looking like an ordinary sleep; still 200, since nothing a
    // retry could fix is missing here.
    await logEvent("slept_orphan", { username, os });
  }
  await dropSession(username);
  return res.status(200).json({ ok: true });
}
