import test from "node:test";
import assert from "node:assert/strict";
import {
  hourlyRate, requestedOs, probeUrl, HOURLY_USD, HOURLY_USD_WINDOWS,
} from "../lib/desktops.js";

test("hourlyRate: linux and undefined use the CPU rate, windows its own", () => {
  assert.equal(hourlyRate("linux"), HOURLY_USD);
  assert.equal(hourlyRate(undefined), HOURLY_USD);
  assert.equal(hourlyRate("windows"), HOURLY_USD_WINDOWS);
  assert.ok(HOURLY_USD_WINDOWS > HOURLY_USD);
});

test("requestedOs: only an admin asking for windows gets windows", () => {
  assert.equal(requestedOs(true, "windows"), "windows");
  assert.equal(requestedOs(false, "windows"), "linux");
  assert.equal(requestedOs(true, "linux"), "linux");
  assert.equal(requestedOs(true, undefined), "linux");
  assert.equal(requestedOs(true, "WINDOWS"), "linux"); // exact match only
  assert.equal(requestedOs(true, { os: "windows" }), "linux");
});

test("probeUrl: /healthz for linux, DCV root for windows, null passes through", () => {
  assert.equal(probeUrl("https://a.desktop.example", "linux"), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", undefined), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", "windows"), "https://a.desktop.example/");
  assert.equal(probeUrl(null, "windows"), null);
});
