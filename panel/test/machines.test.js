import test from "node:test";
import assert from "node:assert/strict";
import {
  MACHINE_OSES, machineKey, startPlan, missingOses, wipeRefusalReason, pendingWakeAction,
} from "../lib/machines.js";

const m = (state, os) => ({ os, state, instance_id: "i-1" });

test("machineKey: one machine per user per OS", () => {
  assert.equal(machineKey("alice", "linux"), "alice:linux");
  assert.equal(machineKey("alice", "windows"), "alice:windows");
  assert.deepEqual(MACHINE_OSES, ["linux", "windows"]);
});

test("startPlan: build when there is no machine, wake when it sleeps, adopt when it already runs", () => {
  assert.deepEqual(startPlan({}, "alice", "linux"), { action: "build", sleepOs: null });
  assert.deepEqual(
    startPlan({ "alice:linux": m("sleeping", "linux") }, "alice", "linux"),
    { action: "wake", sleepOs: null }
  );
  assert.deepEqual(
    startPlan({ "alice:linux": m("running", "linux") }, "alice", "linux"),
    { action: "adopt", sleepOs: null }
  );
  // a machine still being built is not ready to wake: the panel waits, it does not build twice
  assert.deepEqual(
    startPlan({ "alice:linux": m("building", "linux") }, "alice", "linux"),
    { action: "adopt", sleepOs: null }
  );
});

test("startPlan: only one machine runs at a time, so the other OS is slept first", () => {
  const machines = {
    "alice:linux": m("running", "linux"),
    "alice:windows": m("sleeping", "windows"),
  };
  assert.deepEqual(startPlan(machines, "alice", "windows"), { action: "wake", sleepOs: "linux" });
  // someone else's running machine never forces a sleep
  const others = { "bob:linux": m("running", "linux"), "alice:windows": m("sleeping", "windows") };
  assert.deepEqual(startPlan(others, "alice", "windows"), { action: "wake", sleepOs: null });
  // building the second OS while the first runs also sleeps the first
  assert.deepEqual(
    startPlan({ "alice:linux": m("running", "linux") }, "alice", "windows"),
    { action: "build", sleepOs: "linux" }
  );
});

test("missingOses: which machines a user still needs built", () => {
  assert.deepEqual(missingOses({}, "alice"), ["linux", "windows"]);
  assert.deepEqual(missingOses({ "alice:linux": m("sleeping", "linux") }, "alice"), ["windows"]);
  assert.deepEqual(
    missingOses({ "alice:linux": m("sleeping", "linux"), "alice:windows": m("running", "windows") }, "alice"),
    []
  );
  // another user's machines are not this user's
  assert.deepEqual(missingOses({ "bob:linux": m("sleeping", "linux") }, "alice"), ["linux", "windows"]);
});

test("startPlan: the OS switch is a sleep then a wake, never two machines running", () => {
  const machines = {
    "alice:linux": { os: "linux", state: "running" },
    "alice:windows": { os: "windows", state: "sleeping" },
  };
  const plan = startPlan(machines, "alice", "windows");
  assert.equal(plan.sleepOs, "linux");
  assert.equal(plan.action, "wake");
  // after the sleep lands, the same call plans a plain wake
  const after = { ...machines, "alice:linux": { os: "linux", state: "sleeping" } };
  assert.deepEqual(startPlan(after, "alice", "windows"), { action: "wake", sleepOs: null });
});

test("wipeRefusalReason: a sleeping machine with no session is fine, a running one with no session is not", () => {
  // A parked machine has NO session record at all - that must not read as
  // "safe to wipe" just because the session hash has nothing for this user.
  const sleeping = { "alice:linux": m("sleeping", "linux") };
  assert.equal(wipeRefusalReason(sleeping, {}, "alice"), null);

  // The transient the guard exists for: sessions and machines are separate
  // hashes updated by different callbacks, so "no session, but the machine
  // is still running" is an expected state to see, not a bug - and it must
  // still refuse.
  const running = { "alice:linux": m("running", "linux") };
  assert.match(wipeRefusalReason(running, {}, "alice"), /running or still building/);

  // A still-building machine refuses the same way.
  const building = { "alice:windows": m("building", "windows") };
  assert.match(wipeRefusalReason(building, {}, "alice"), /running or still building/);

  // A live session refuses even before any machine record exists.
  assert.match(
    wipeRefusalReason({}, { alice: { status: "building" } }, "alice"),
    /destroy it first/
  );

  // Someone else's running machine never blocks this user's wipe.
  const others = { "bob:linux": m("running", "linux") };
  assert.equal(wipeRefusalReason(others, {}, "alice"), null);
});

test("missingOses drives the sign-in build: nothing to build once both exist", () => {
  const building = { "alice:linux": { os: "linux", state: "building" } };
  assert.deepEqual(missingOses(building, "alice"), ["windows"]);
  const both = { ...building, "alice:windows": { os: "windows", state: "building" } };
  assert.deepEqual(missingOses(both, "alice"), []);
});

test("pendingWakeAction: the controller-ruling gap - a switch to an OS the user never had must build, not wake", () => {
  // Task 5's handler only ever dispatched a wake for the pending OS, which
  // left a user with nothing at all if they switched to an OS they have no
  // machine for while their other one was running. This is the fix: build
  // when there is no machine record yet for that OS...
  assert.equal(pendingWakeAction({}, "alice", "windows"), "build");
  assert.equal(
    pendingWakeAction({ "alice:linux": m("running", "linux") }, "alice", "windows"),
    "build"
  );
  // ...and wake when a machine record already exists for it, parked or not -
  // pendingWakeAction does not need to distinguish sleeping from running
  // here, because session-slept only calls it for the OS the switch is going
  // TO, which by construction is never the one that just stopped.
  assert.equal(
    pendingWakeAction({ "alice:windows": m("sleeping", "windows") }, "alice", "windows"),
    "wake"
  );
  assert.equal(
    pendingWakeAction({ "alice:windows": m("running", "windows") }, "alice", "windows"),
    "wake"
  );
  // Someone else's machine for that OS never counts as this user's.
  assert.equal(
    pendingWakeAction({ "bob:windows": m("running", "windows") }, "alice", "windows"),
    "build"
  );
  // A deleted machine is not "there" for a switch either - build it fresh.
  assert.equal(pendingWakeAction({ "alice:windows": m("deleted", "windows") }, "alice", "windows"), "build");
});

test("Fix round 1 (Critical 1): a deleted machine is a tombstone, not a gap - missingOses must not auto-rebuild it", () => {
  // api/session-ended.js now writes {state: "deleted"} instead of dropping
  // the record outright. missingOses() must treat that record as NOT
  // missing, or the very next /api/status poll's sign-in build would rebuild
  // a machine the user just chose to delete - real money against explicit
  // intent.
  const deleted = { "alice:linux": m("deleted", "linux") };
  assert.deepEqual(missingOses(deleted, "alice"), ["windows"]);
  const bothDeleted = { ...deleted, "alice:windows": m("deleted", "windows") };
  assert.deepEqual(missingOses(bothDeleted, "alice"), []);
});

test("Fix round 1 (Critical 1): a manual Start still rebuilds a deleted machine", () => {
  // Unlike missingOses (the automatic sign-in build), a MANUAL Start must
  // still be able to bring a deliberately-deleted machine back - startPlan
  // treats "deleted" the same as "no record at all".
  assert.deepEqual(startPlan({ "alice:linux": m("deleted", "linux") }, "alice", "linux"), {
    action: "build",
    sleepOs: null,
  });
  // Deleting one OS while the other still runs still sleeps the other first.
  const machines = { "alice:linux": m("running", "linux"), "alice:windows": m("deleted", "windows") };
  assert.deepEqual(startPlan(machines, "alice", "windows"), { action: "build", sleepOs: "linux" });
});

test("Fix round 1 (Critical 1): a deleted machine does not block a wipe", () => {
  const deleted = { "alice:linux": m("deleted", "linux") };
  assert.equal(wipeRefusalReason(deleted, {}, "alice"), null);
});
