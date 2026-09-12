import test from "node:test";
import assert from "node:assert/strict";
import {
  hourlyRate, requestedOs, probeUrl, HOURLY_USD, HOURLY_USD_WINDOWS, requestedRegion, REGIONS,
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

test("requestedRegion: only an admin asking for a known region gets it, else the default", () => {
  assert.equal(requestedRegion(true, "ap-south-1"), "ap-south-1");
  assert.equal(requestedRegion(true, "ap-south-1"), "ap-south-1");
  assert.equal(requestedRegion(true, "eu-west-1"), "ap-south-1"); // unknown region
  assert.equal(requestedRegion(true, "me-central-1"), "ap-south-1"); // not offered any more
  assert.equal(requestedRegion(true, undefined), "ap-south-1");
  assert.ok(Object.keys(REGIONS).includes("ap-south-1"));
  assert.deepEqual(Object.keys(REGIONS), ["ap-south-1"]);
});

test("probeUrl: /healthz for linux, DCV root for windows, null passes through", () => {
  assert.equal(probeUrl("https://a.desktop.example", "linux"), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", undefined), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", "windows"), "https://a.desktop.example/");
  assert.equal(probeUrl(null, "windows"), null);
});
