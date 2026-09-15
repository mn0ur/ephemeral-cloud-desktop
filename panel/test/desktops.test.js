import test from "node:test";
import assert from "node:assert/strict";
import {
  hourlyRate, requestedOs, probeUrl, HOURLY_USD, HOURLY_USD_WINDOWS, requestedRegion, REGIONS,
  sessionPhase, canCancel, CANCEL_AFTER_S, runBelongsTo,
} from "../lib/desktops.js";

test("hourlyRate: linux and undefined use the CPU rate, windows its own", () => {
  assert.equal(hourlyRate("linux"), HOURLY_USD);
  assert.equal(hourlyRate(undefined), HOURLY_USD);
  assert.equal(hourlyRate("windows"), HOURLY_USD_WINDOWS);
  assert.ok(HOURLY_USD_WINDOWS > HOURLY_USD);
});

test("requestedOs: every tier may choose windows; anything else is linux", () => {
  assert.equal(requestedOs("windows"), "windows");
  assert.equal(requestedOs("linux"), "linux");
  assert.equal(requestedOs(undefined), "linux");
  assert.equal(requestedOs("WINDOWS"), "linux"); // exact match only
  assert.equal(requestedOs({ os: "windows" }), "linux");
});

test("requestedRegion: only an admin asking for a known region gets it, else the default", () => {
  assert.equal(requestedRegion(true, "ap-south-1"), "ap-south-1");
  assert.equal(requestedRegion(true, "eu-west-1"), "ap-south-1"); // unknown region
  assert.equal(requestedRegion(true, "me-central-1"), "ap-south-1"); // not offered any more
  assert.equal(requestedRegion(true, undefined), "ap-south-1");
  assert.deepEqual(Object.keys(REGIONS), ["ap-south-1"]);
});

test("probeUrl: /healthz for linux, DCV root for windows, null passes through", () => {
  assert.equal(probeUrl("https://a.desktop.example", "linux"), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", undefined), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", "windows"), "https://a.desktop.example/");
  assert.equal(probeUrl(null, "windows"), null);
});

test("sessionPhase: no session is null; pending is starting, never an existing machine", () => {
  assert.equal(sessionPhase(null), null);
  assert.equal(sessionPhase(undefined), null);
  assert.equal(sessionPhase({ status: "pending", dispatched_at: 1 }), "starting");
  assert.equal(sessionPhase({ status: "ready", url: "https://x", password: "p" }), "booting");
  assert.equal(sessionPhase({ status: "active", url: "https://x", password: "p" }), "running");
  assert.equal(sessionPhase({ status: "error" }), "error");
  // A destroy in flight wins over whatever status the start reached.
  assert.equal(sessionPhase({ status: "active", destroy_dispatched_at: 5 }), "destroying");
  assert.equal(sessionPhase({ status: "pending", destroy_dispatched_at: 5 }), "destroying");
});

test("canCancel: hidden for the first minute of a start, then allowed; always for a real machine", () => {
  const t0 = 1000;
  const starting = { status: "pending", dispatched_at: t0 };
  assert.equal(CANCEL_AFTER_S, 60);
  assert.equal(canCancel(starting, t0 + 5), false);
  assert.equal(canCancel(starting, t0 + 59), false);
  assert.equal(canCancel(starting, t0 + 60), true);
  assert.equal(canCancel({ status: "ready", url: "u", password: "p", dispatched_at: t0 }, t0 + 1), true);
  assert.equal(canCancel({ status: "active", url: "u", password: "p" }, t0), true);
  assert.equal(canCancel({ status: "active", destroy_dispatched_at: t0 }, t0 + 999), false);
  assert.equal(canCancel(null, t0), false);
});

test("runBelongsTo: only this user's desktop runs, not a user whose name merely starts the same", () => {
  const at = (iso) => ({ created_at: iso });
  const since = Date.parse("2026-09-15T13:47:50Z") / 1000;
  const mine = { name: "Desktop - START · mohd-muj-mam · linux", ...at("2026-09-15T13:47:56Z") };
  assert.equal(runBelongsTo(mine, "mohd-muj-mam", since), true);
  assert.equal(runBelongsTo({ ...mine, name: "Desktop - DESTROY · mohd-muj-mam" }, "mohd-muj-mam", since), true);
  // someone else's run, the owner's name as a prefix of another user, and unlabelled runs
  assert.equal(runBelongsTo({ ...mine, name: "Desktop - START · mnuowr · windows" }, "mohd-muj-mam", since), false);
  assert.equal(runBelongsTo({ ...mine, name: "Desktop - START · mnuowr-2 · linux" }, "mnuowr", since), false);
  assert.equal(runBelongsTo({ ...mine, name: "Desktop - START" }, "mohd-muj-mam", since), false);
  assert.equal(runBelongsTo({ ...mine, name: "Bake Desktop AMI · mohd-muj-mam" }, "mohd-muj-mam", since), false);
  // an old run of the same user from before this action is not "this" start
  assert.equal(runBelongsTo({ ...mine, created_at: "2026-09-15T13:30:00Z" }, "mohd-muj-mam", since), false);
  assert.equal(runBelongsTo(mine, "mohd-muj-mam", undefined), true);
});
