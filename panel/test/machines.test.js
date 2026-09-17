import test from "node:test";
import assert from "node:assert/strict";
import { MACHINE_OSES, machineKey, startPlan, missingOses, wipeRefusalReason } from "../lib/machines.js";

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
