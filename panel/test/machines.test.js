import test from "node:test";
import assert from "node:assert/strict";
import { MACHINE_OSES, machineKey, startPlan, missingOses } from "../lib/machines.js";

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
