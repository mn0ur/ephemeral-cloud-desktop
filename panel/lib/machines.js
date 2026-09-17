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

export function missingOses(machines, username) {
  return MACHINE_OSES.filter((os) => !machines[machineKey(username, os)]);
}

// What Start should do, and whether the user's OTHER machine has to be put to
// sleep first. Only one machine per user runs at a time, so nobody can run up
// two hourly bills at once (spec decision, 2026-09-17).
export function startPlan(machines, username, os) {
  const mine = machines[machineKey(username, os)];
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
  if (!mine) return { action: "build", sleepOs };
  if (mine.state === "sleeping") return { action: "wake", sleepOs };
  return { action: "adopt", sleepOs };
}
