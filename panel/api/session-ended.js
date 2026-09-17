// session-ended and session-slept used to be two separate files. The Vercel
// Hobby plan caps a deployment at 12 Serverless Functions - panel/api/ was
// already at 12, and adding session-slept.js as a 13th pushed the count over
// the limit and the deploy was rejected outright (errorCode
// exceeded_serverless_functions_per_deployment, hit 2026-09-17). Merging them
// is not just a workaround for the cap: both callbacks mean "this session is
// over", and `reason` ("manual" | "time_limit" | "reclaimed" | "slept") is
// what decides what happens to the MACHINE. Do NOT split this back into two
// files without first freeing up a function slot elsewhere - that will just
// break the deploy again.

import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession,
  loadMachines, putMachine, logEvent,
} from "../lib/state.js";
import { MACHINE_OSES, machineKey, pendingWakeAction } from "../lib/machines.js";
import { dispatch, WORKFLOWS } from "../lib/github.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });

  const sessions = await loadSessions();
  const prior = sessions[username] || {};

  // Which machine this callback is about decides which record gets touched,
  // so a wrong answer here either sleeps/tombstones the machine that is
  // still there and leaves the real one looking alive. Silently defaulting
  // to "linux" did exactly that for any caller that forgot the field; there
  // is no safe guess, so an unnameable OS is a 400 - checked BEFORE anything
  // is written.
  const os = req.body?.os || prior.os;
  if (!MACHINE_OSES.includes(os)) {
    return res.status(400).json({ error: "os is required (linux or windows)" });
  }

  const reason = req.body?.reason || "manual";

  if (reason === "slept") {
    // Called by desktop-sleep.yml once the machine is stopped. The machine
    // RECORD survives - that is the difference between sleeping and being
    // destroyed - but the session is over.
    const machines = await loadMachines();
    const machinePrior = machines[machineKey(username, os)];
    if (machinePrior) {
      await putMachine(username, os, { ...machinePrior, state: "sleeping", slept_at: Date.now() / 1000 });
      await logEvent("slept", { username, os });
    } else {
      // The machine IS stopped (the workflow only calls this after a
      // confirmed stop) but there was no record to update - an out-of-band
      // delete raced this callback. Distinct event so the mismatch shows up
      // in history instead of looking like an ordinary sleep; still 200,
      // since nothing a retry could fix is missing here.
      await logEvent("slept_orphan", { username, os });
    }

    // An OS switch is a sleep followed by a build-or-wake. That second half
    // is dispatched HERE, when the first machine is actually confirmed
    // stopped, so the panel never has two machines running for one person.
    // Which of the two it is depends on whether `pending.os` already has a
    // machine record: a first-time switch to an OS this user has never had
    // needs a real build (desktop-up.yml), not a wake of something that does
    // not exist yet - this is the gap Task 5 left (startPlan can return
    // {action: "build", sleepOs} when the OTHER machine is running, and the
    // old handler only ever woke the pending OS).
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

  // Destroy path: reason is "manual", "time_limit", "reclaimed", or anything
  // else a caller sends that is not "slept".
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
    reason,
  });
  return res.status(200).json({ ok: true });
}
