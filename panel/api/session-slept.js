import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadMachines, putMachine, loadSessions, putSession, dropSession, logEvent } from "../lib/state.js";
import { machineKey, pendingWakeAction } from "../lib/machines.js";
import { dispatch, WORKFLOWS } from "../lib/github.js";

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

  // An OS switch is a sleep followed by a build-or-wake. That second half is
  // dispatched HERE, when the first machine is actually confirmed stopped,
  // so the panel never has two machines running for one person. Which of the
  // two it is depends on whether `pending.os` already has a machine record:
  // a first-time switch to an OS this user has never had needs a real build
  // (desktop-up.yml), not a wake of something that does not exist yet -
  // this is the gap Task 5 left (startPlan can return {action: "build",
  // sleepOs} when the OTHER machine is running, and the old handler only
  // ever woke the pending OS).
  const sessions = await loadSessions();
  const pending = sessions[username];
  if (pending?.pending_wake && pending.os && pending.os !== os) {
    const region = pending.region || "ap-south-1";
    const action = pendingWakeAction(machines, username, pending.os);
    try {
      if (action === "build") {
        await dispatch(WORKFLOWS.start, {
          username, fresh: "false", guest_username: username,
          owner_email: pending.email || "", persist: "true", is_guest: "false",
          os: pending.os, region, use_spot: "false",
        });
        await putSession(username, {
          status: "building", email: pending.email, dispatched_at: Date.now() / 1000,
          os: pending.os, region,
          // The user DID ask for this (they picked the other OS at Start) -
          // unlike the sign-in build in api/status.js, session-ready must
          // not park this one the moment it comes up.
          start_requested: true,
        });
      } else {
        await dispatch(WORKFLOWS.wake, { guest_username: username, os: pending.os });
        await putSession(username, {
          status: "waking", email: pending.email, dispatched_at: Date.now() / 1000,
          os: pending.os, region,
        });
      }
      await logEvent("switch_os", { username, from: os, to: pending.os, via: action });
      return res.status(200).json({ ok: true, [action === "build" ? "built" : "woke"]: pending.os });
    } catch (e) {
      // Fall through: the machine IS asleep, and the user can press Start again.
      console.error("pending wake dispatch failed", e.message);
    }
  }

  await dropSession(username);
  return res.status(200).json({ ok: true });
}
