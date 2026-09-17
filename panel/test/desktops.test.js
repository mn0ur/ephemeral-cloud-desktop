import test from "node:test";
import assert from "node:assert/strict";
import {
  hourlyRate, requestedOs, probeUrl, HOURLY_USD, HOURLY_USD_WINDOWS, requestedRegion, REGIONS,
  sessionPhase, canCancel, CANCEL_AFTER_S, runBelongsTo,
  HOURLY_USD_ONDEMAND, UNREACHABLE_AFTER_S, HEALTH_EVERY_S, healthCheckDue, applyHealth,
  hashToken, tokenMatches, startRefusalReason,
} from "../lib/desktops.js";

test("hourlyRate: linux and undefined use the CPU rate, windows its own", () => {
  assert.equal(hourlyRate("linux"), HOURLY_USD);
  assert.equal(hourlyRate(undefined), HOURLY_USD);
  assert.equal(hourlyRate("windows", "on-demand"), HOURLY_USD_WINDOWS);
  assert.ok(HOURLY_USD_WINDOWS > HOURLY_USD);
});

test("requestedOs: every tier may choose windows; anything else is linux", () => {
  assert.equal(requestedOs("windows"), "windows");
  assert.equal(requestedOs("linux"), "linux");
  assert.equal(requestedOs(undefined), "linux");
  assert.equal(requestedOs("WINDOWS"), "linux"); // exact match only
  assert.equal(requestedOs({ os: "windows" }), "linux");
});

test("requestedRegion: ap-south-1 is the only region, whatever is asked for", () => {
  assert.equal(requestedRegion("ap-south-1"), "ap-south-1");
  assert.equal(requestedRegion("me-central-1"), "ap-south-1");
  assert.equal(requestedRegion(undefined), "ap-south-1");
  assert.deepEqual(Object.keys(REGIONS), ["ap-south-1"]);
  // Single argument only. A second parameter reappearing would mean someone
  // reintroduced an isAdmin gate (what this test can't otherwise catch: with
  // REGIONS holding exactly one key equal to the function's own fallback,
  // every legal input returns that same value under this implementation, the
  // old two-arg one, or a stub that ignores its argument entirely).
  assert.equal(requestedRegion.length, 1);
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

test("sessionPhase: a first build and a wake are different waits, and neither is 'running'", () => {
  assert.equal(sessionPhase({ status: "building" }), "building");
  assert.equal(sessionPhase({ status: "waking" }), "waking");
  // a sleep in flight reads as destroying-style shutdown, not as running
  assert.equal(sessionPhase({ status: "active", sleep_dispatched_at: 1 }), "sleeping");
  // and an actual delete still wins
  assert.equal(sessionPhase({ status: "active", destroy_dispatched_at: 1, sleep_dispatched_at: 1 }), "destroying");
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

test("runBelongsTo: only this user's run for this action, not a user whose name merely starts the same", () => {
  const since = Date.parse("2026-09-15T13:47:50Z") / 1000;
  // GitHub returns run-name as display_title; name is always the workflow name
  const run = (title, created = "2026-09-15T13:47:56Z") => ({ name: title.split(" · ")[0], display_title: title, created_at: created });
  const mine = run("Desktop - START · mohd-muj-mam · linux");
  assert.equal(runBelongsTo(mine, "mohd-muj-mam", since), true);
  assert.equal(runBelongsTo(mine, "mohd-muj-mam", since, "START"), true);
  assert.equal(runBelongsTo(run("Desktop - DESTROY · mohd-muj-mam"), "mohd-muj-mam", since, "DESTROY"), true);
  // the other action's run is not this one (a finished DESTROY under "Starting…")
  assert.equal(runBelongsTo(run("Desktop - DESTROY · mohd-muj-mam"), "mohd-muj-mam", since, "START"), false);
  assert.equal(runBelongsTo(mine, "mohd-muj-mam", since, "DESTROY"), false);
  // someone else's run, the owner's name as a prefix of another user, and unlabelled runs
  assert.equal(runBelongsTo(run("Desktop - START · mnuowr · windows"), "mohd-muj-mam", since), false);
  assert.equal(runBelongsTo(run("Desktop - START · mnuowr-2 · linux"), "mnuowr", since), false);
  assert.equal(runBelongsTo(run("Desktop - START"), "mohd-muj-mam", since), false);
  assert.equal(runBelongsTo(run("Bake Desktop AMI · mohd-muj-mam"), "mohd-muj-mam", since), false);
  // name alone never matches: before run-name existed name and title were equal, after it they differ
  assert.equal(runBelongsTo({ ...mine, display_title: undefined }, "mohd-muj-mam", since), false);
  // an earlier run of the same user from before this action is not "this" one
  assert.equal(runBelongsTo(run("Desktop - START · mohd-muj-mam · linux", "2026-09-15T13:47:00Z"), "mohd-muj-mam", since), false);
  assert.equal(runBelongsTo(mine, "mohd-muj-mam", undefined), true);
});

test("hourlyRate: what the machine actually costs - Windows always on-demand, Linux by market", () => {
  assert.equal(hourlyRate("linux", "spot"), HOURLY_USD);
  assert.equal(hourlyRate("linux", "on-demand"), HOURLY_USD_ONDEMAND);
  assert.equal(hourlyRate("windows", "on-demand"), HOURLY_USD_WINDOWS);
  assert.equal(HOURLY_USD_WINDOWS, 0.3625);
  // Windows sessions from before this change were spot and bill the spot rate
  assert.equal(hourlyRate("windows", undefined), 0.204);
  assert.equal(HOURLY_USD_ONDEMAND, 0.1785);
});

test("sessionPhase: a running desktop that stopped answering becomes unreachable, not 'Running'", () => {
  const t0 = 1_800_000_000;
  const s = { status: "active", unreachable_since: t0 };
  assert.equal(sessionPhase(s, t0 + 10), "running"); // one blip is not a verdict
  assert.equal(sessionPhase(s, t0 + UNREACHABLE_AFTER_S), "unreachable");
  assert.equal(sessionPhase({ status: "active" }, t0), "running");
  // a cleanup already dispatched wins over everything
  assert.equal(sessionPhase({ ...s, destroy_dispatched_at: t0 }, t0 + 999), "destroying");
});

test("healthCheckDue/applyHealth: re-probe a running desktop every HEALTH_EVERY_S and track since when it is down", () => {
  const t0 = 1_800_000_000;
  assert.equal(healthCheckDue({ status: "active" }, t0), true);
  assert.equal(healthCheckDue({ status: "active", checked_at: t0 }, t0 + HEALTH_EVERY_S - 1), false);
  assert.equal(healthCheckDue({ status: "active", checked_at: t0 }, t0 + HEALTH_EVERY_S), true);
  assert.equal(healthCheckDue({ status: "ready" }, t0), false);
  assert.equal(healthCheckDue({ status: "active", destroy_dispatched_at: t0 }, t0 + 999), false);
  const down1 = applyHealth({ status: "active" }, false, t0);
  assert.equal(down1.unreachable_since, t0);
  const down2 = applyHealth(down1, false, t0 + 30);
  assert.equal(down2.unreachable_since, t0); // keeps the FIRST failure
  const back = applyHealth(down2, true, t0 + 60);
  assert.equal(back.unreachable_since, undefined);
  assert.equal(back.checked_at, t0 + 60);
});

test("tokenMatches: only the exact per-session token proves a reclaim notice", () => {
  const h = hashToken("a".repeat(48));
  assert.equal(tokenMatches("a".repeat(48), h), true);
  assert.equal(tokenMatches("b".repeat(48), h), false);
  assert.equal(tokenMatches("", h), false);
  assert.equal(tokenMatches(undefined, h), false);
  assert.equal(tokenMatches("a".repeat(48), undefined), false);
  assert.notEqual(h, "a".repeat(48)); // stored hashed, never raw
});

test("startRefusalReason: only accounts with access may start, and only one desktop each", () => {
  const ok = { has_access: true, is_admin: false };
  assert.equal(startRefusalReason(ok, null), null);
  assert.equal(
    startRefusalReason({ has_access: false, is_admin: false }, null),
    "Your account doesn't have access to Sihaab yet. Ask the owner to add you."
  );
  // an admin always has access
  assert.equal(startRefusalReason({ has_access: true, is_admin: true }, null), null);
  // already running or starting: one desktop per person
  for (const status of ["pending", "ready", "active"]) {
    assert.equal(startRefusalReason(ok, { status }), "you already have a desktop running");
  }
  // a finished/errored session is not in the way
  assert.equal(startRefusalReason(ok, { status: "error" }), null);
  assert.equal(startRefusalReason(undefined, null), "sign in first");
});
