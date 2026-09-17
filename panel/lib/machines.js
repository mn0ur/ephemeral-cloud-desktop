// A MACHINE outlives a session. Each permanent user has two - one Linux, one
// Windows - parked (EC2 stopped) when unused, because a stopped machine costs
// only its disk (~$4/month Windows, ~$2.50 Linux) and starts in ~40-60s
// instead of the ~3 minutes a build takes.
//
// Sessions say "someone is using a desktop right now"; machines say "this
// person has a desktop that exists". Keeping them apart is what lets Start
// become a wake.
//
// No imports here: state.js imports this module, and a cycle back would break
// the serverless bundle.

export const MACHINE_OSES = ["linux", "windows"];

export function machineKey(username, os) {
  // Collision-safe only because usernameFor() in panel/lib/state.js sanitises
  // usernames to [a-z0-9-], which strips ":" - if that character set is ever
  // widened, a username like "alice:linux" would collide with alice's Linux
  // machine. This file imports nothing, so it cannot enforce that itself;
  // check state.js before loosening username rules, and check here before
  // relying on this key format elsewhere.
  return `${username}:${os}`;
}

// A "deleted" record is a TOMBSTONE (api/session-ended.js), not the absence
// of one - it exists specifically so this function does NOT treat a
// deliberately-deleted machine as "missing" and hand it back to the sign-in
// build in api/status.js. A manual Start must still rebuild a deleted
// machine - that goes through startPlan below, which checks state
// explicitly rather than relying on missingOses.
export function missingOses(machines, username, now = Date.now() / 1000) {
  return MACHINE_OSES.filter((os) => {
    const mine = machines[machineKey(username, os)];
    return !mine || staleBuild(mine, now);
  });
}

// How long a record may sit in state "building" before it is treated as a
// build that died. A build that never calls back (a cancelled run, a failed
// terraform apply, a GitHub outage between dispatch and callback) leaves a
// record that is neither a machine nor an absence: missingOses would never
// rebuild it, startPlan would answer "adopt" so Start did nothing, and a wipe
// would be refused because the record reads as live - wedging that OS for
// that user permanently, with no session and so no delete path either.
//
// 20 minutes is deliberately far past the longest real build measured
// (Linux ~5.5 min end to end, Windows ~3 min) plus GitHub queueing, so this
// can only ever fire on a build that is genuinely not coming back.
export const BUILD_STALE_S = 20 * 60;

// A "building" record older than BUILD_STALE_S counts as ABSENT everywhere a
// machine is looked up. Records written before building_since existed have no
// timestamp; created_at is stamped at the same moment by every writer, so it
// is the fallback. With neither, the record is NOT treated as stale - an
// unknown age must not hand a live build to a second dispatch.
export function staleBuild(machine, now = Date.now() / 1000) {
  if (!machine || machine.state !== "building") return false;
  const since = Number(machine.building_since ?? machine.created_at);
  if (!Number.isFinite(since) || since <= 0) return false;
  return now - since >= BUILD_STALE_S;
}

// What to dispatch for the OS a user is switching TO, once their other
// machine has actually stopped (api/session-ended.js's reason:"slept" path).
// A switch is "sleep the running one, then bring up the one asked for" - and
// "bring up" means build when that OS has no LIVE machine yet (no record at
// all, or a "deleted" tombstone), wake when a real one exists (parked or
// otherwise; the reason:"slept" handler only ever reaches this once the
// OTHER os has just been confirmed asleep, so `os` itself cannot be the one
// that just stopped).
export function pendingWakeAction(machines, username, os) {
  const mine = machines[machineKey(username, os)];
  return mine && mine.state !== "deleted" ? "wake" : "build";
}

// What Start should do, and whether the user's OTHER machine has to be put to
// sleep first. Only one machine per user runs at a time, so nobody can run up
// two hourly bills at once (spec decision, 2026-09-17).
export function startPlan(machines, username, os, now = Date.now() / 1000) {
  const raw = machines[machineKey(username, os)];
  // A build that died mid-flight is not a machine - see staleBuild. Treating
  // it as absent here is what lets the next Start rebuild it instead of
  // answering "adopt" forever.
  const mine = staleBuild(raw, now) ? null : raw;
  const otherOs = MACHINE_OSES.find((o) => o !== os);
  const other = machines[machineKey(username, otherOs)];
  const sleepOs = other && other.state === "running" ? otherOs : null;

  // "building" is not "ready to wake" and not "nothing there": a second
  // dispatch would build a duplicate machine, so the page waits instead.
  //
  // "adopt" covers two different realities: the machine is already running
  // and reachable, or it is still being built with nothing to attach to yet.
  // Either way there is nothing for the caller to dispatch here - it means
  // "do not start anything, keep polling". A caller that needs to tell
  // running from still-building apart must read the machine's own `state`
  // field itself; this function does not distinguish them in its return.
  //
  // A "deleted" record (api/session-ended.js's tombstone) is treated the
  // same as no record at all here - a MANUAL Start is exactly the one place
  // a deliberately-deleted machine SHOULD be rebuilt; only the automatic
  // sign-in build (missingOses, in api/status.js) must leave it alone.
  if (!mine || mine.state === "deleted") return { action: "build", sleepOs };
  if (mine.state === "sleeping") return { action: "wake", sleepOs };
  return { action: "adopt", sleepOs };
}

// Whether a wipe of `username`'s saved data must be refused, and why. Pulled
// out of the dispatch handler so the two things it actually checks - the
// session status, and the machine's own state - are unit-testable without a
// mocked request/response pair.
//
// Sessions and machines are separate hashes, written by different callbacks,
// and are NOT updated atomically - "session says running, machine says
// sleeping" (or the reverse) is an expected transient, not a bug. A sleeping
// machine has NO session record at all, so checking sessions alone would let
// a wipe through against a machine that merely LOOKS gone because nobody
// updated its session yet. Checking machines alone would miss a session
// that is live (building/waking) before any machine record exists at all.
// Both are checked; either one being "live" refuses.
//
// Keep this status list in step with LIVE_STATUSES in lib/desktops.js - not
// imported from there because this file imports nothing (see the top of the
// file: state.js imports this module, and a cycle back would break the
// serverless bundle).
const SESSION_LIVE_STATUSES = ["pending", "building", "waking", "ready", "active"];

export function wipeRefusalReason(machines, sessions, username) {
  if (SESSION_LIVE_STATUSES.includes(sessions[username]?.status)) {
    return "that desktop is running - destroy it first, then delete the data";
  }
  // A "deleted" tombstone is deliberately NOT in this list - the whole point
  // of deleting a machine is that its saved data can then be wiped, so a
  // "deleted" record must never read as "live" here.
  const liveMachine = MACHINE_OSES.some((os) =>
    ["running", "building"].includes(machines[machineKey(username, os)]?.state)
  );
  if (liveMachine) {
    return "that desktop is running or still building - destroy it first, then delete the data";
  }
  return null;
}

// Which machine a delete acts on.
//
// During an OS switch the session carries BOTH machines: `os`/`wake_os` is the
// one being brought up, `sleep_os` is the one still running and being stopped.
// A delete in that window must target the running machine, not the one the
// user is switching to - reading session.os there destroyed the wrong desktop
// (review finding, 2026-09-17).
//
// An explicit, validated OS in the request body always wins: that is how the
// Start card deletes a PARKED machine, which has no session at all. Returns
// null when nothing names an OS - the caller answers 404 rather than guessing.
export function deleteOs(session, bodyOs) {
  if (MACHINE_OSES.includes(bodyOs)) return bodyOs;
  if (!session) return null;
  if (MACHINE_OSES.includes(session.sleep_os)) return session.sleep_os;
  if (MACHINE_OSES.includes(session.os)) return session.os;
  return null;
}
