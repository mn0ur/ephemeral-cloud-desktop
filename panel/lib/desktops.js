// Desktop liveness and session reconciliation.

import crypto from "node:crypto";

export const DESKTOP_DOMAIN = process.env.DESKTOP_DOMAIN || "desktop.sihaab.com";
export const MAX_CONCURRENT = Number(process.env.MAX_CONCURRENT || 5);
// c7i.xlarge spot in me-central-1a, measured 2026-08-25. Keep in step with
// terraform/variables.tf: a region move that forgets this line makes the
// panel lie about money. History: eu-central-1 0.104, ap-south-1c 0.0529.
//
// This is the CPU price. A gpu=true session runs g5.xlarge at ~0.505/hr, so
// the figure shown to a GPU user is currently ~6x low - the panel has no
// per-session notion of instance type yet. Worth wiring through before GPU
// sessions are offered to anyone but the operator.
export const HOURLY_USD = Number(process.env.HOURLY_USD || 0.0529);
// Linux on-demand, used when spot had no capacity and the start fell back
// (desktop-up.yml). c7i.xlarge ap-south-1, AWS Price List 2026-09-15.
export const HOURLY_USD_ONDEMAND = Number(process.env.HOURLY_USD_ONDEMAND || 0.1785);
// Windows is ALWAYS on-demand (terraform local.spot): AWS reclaimed a Windows
// spot machine 22 minutes into a session on 2026-09-15, and spot barely
// discounts Windows anyway because the licence part is not discounted
// (spot ~0.204). c7i.xlarge Windows ap-south-1, AWS Price List 2026-09-15.
export const HOURLY_USD_WINDOWS = Number(process.env.HOURLY_USD_WINDOWS || 0.3625);
// Only for Windows sessions started before Windows went on-demand (no market
// recorded); session-ready records every new Windows session as on-demand.
export const HOURLY_USD_WINDOWS_SPOT = 0.204;
export const PENDING_TIMEOUT_S = 10 * 60;

export function hourlyRate(os, market) {
  if (os === "windows") return market === "on-demand" ? HOURLY_USD_WINDOWS : HOURLY_USD_WINDOWS_SPOT;
  return market === "on-demand" ? HOURLY_USD_ONDEMAND : HOURLY_USD;
}

// Every tier chooses its OS at Start (owner decision 2026-09-15). Only an
// admin or a permanent user can start at all - see startRefusalReason.
// Nothing caps how long a session runs; auto-sleep is a later plan. Exact
// match only - anything that is not the string "windows" is linux, so a
// malformed body can never select something unexpected.
export function requestedOs(bodyOs) {
  return bodyOs === "windows" ? "windows" : "linux";
}

// Guests were removed on 2026-09-17: only an admin or a permanent user may
// start a desktop. The client hides the button, but this is the enforcement
// point - the client is only a hint, same rule as os and region.
export const NO_ACCESS_MESSAGE =
  "Your account doesn't have access to Sihaab yet. Ask the owner to add you.";

// A session occupies a slot - counts against MAX_CONCURRENT, blocks a second
// Start, blocks a wipe - from the moment something is dispatched for it until
// it either answers or is torn down. "building" and "waking" are exactly
// "pending" was before Task 5 split it in two (a fresh build vs. a wake of a
// parked machine): both are still "nothing to attach to yet, don't dispatch
// again".
export const LIVE_STATUSES = ["pending", "building", "waking", "ready", "active"];

export function startRefusalReason(session, existingSession) {
  if (!session) return "sign in first";
  if (!session.has_access) return NO_ACCESS_MESSAGE;
  if (LIVE_STATUSES.includes(existingSession?.status)) {
    return "you already have a desktop running";
  }
  return null;
}

// What the user's session IS, from their point of view. Derived on the server
// so the page never has to guess from raw fields - it guessed wrong: a
// just-dispatched start (status "pending", no password yet) was drawn as an
// existing machine with "Password not recorded - this desktop was recovered",
// and a new user destroyed their own start twice believing a machine had
// already been running before they arrived (2026-09-15).
export function sessionPhase(s, now = Date.now() / 1000) {
  if (!s) return null;
  if (s.destroy_dispatched_at) return "destroying";
  if (s.sleep_dispatched_at) return "sleeping";
  if (s.status === "building") return "building";
  if (s.status === "waking") return "waking";
  if (s.status === "error") return "error";
  if (s.status === "active") {
    return s.unreachable_since && now - s.unreachable_since >= UNREACHABLE_AFTER_S ? "unreachable" : "running";
  }
  if (s.status === "ready") return "booting";
  return "starting";
}

// The first minute of a start offers no Cancel: a destroy dispatched then
// only queues behind the apply anyway, and an immediate Cancel is almost
// always a misread of the screen, not an intent.
export const CANCEL_AFTER_S = 60;

// A running desktop is re-probed every HEALTH_EVERY_S and called unreachable
// after UNREACHABLE_AFTER_S of failures. Once "active" nothing used to look
// again, so a machine AWS had reclaimed showed "Running" with an Open button
// for as long as anyone cared to look (2026-09-15). 3 minutes, not one probe:
// a Windows restart or a network blip must not read as a lost machine.
export const HEALTH_EVERY_S = 30;
export const UNREACHABLE_AFTER_S = 180;

export function healthCheckDue(s, now = Date.now() / 1000) {
  if (!s || s.status !== "active" || s.destroy_dispatched_at) return false;
  return now - (Number(s.checked_at) || 0) >= HEALTH_EVERY_S;
}

export function applyHealth(s, up, now = Date.now() / 1000) {
  const next = { ...s, checked_at: now };
  if (up) delete next.unreachable_since;
  else next.unreachable_since = s.unreachable_since || now;
  return next;
}

// The per-session reclaim token (desktop-up.yml -> the machine and
// session-ready). Only its hash is stored; the raw value lives on the machine.
export function hashToken(token) {
  return crypto.createHash("sha256").update(String(token)).digest("hex");
}

export function tokenMatches(token, storedHash) {
  if (!token || !storedHash) return false;
  const a = Buffer.from(hashToken(token));
  const b = Buffer.from(String(storedHash));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export function canCancel(s, now = Date.now() / 1000) {
  const phase = sessionPhase(s);
  if (phase === "booting" || phase === "running") return true;
  if (phase === "starting") return now - (Number(s.dispatched_at) || 0) >= CANCEL_AFTER_S;
  return false;
}

// Workflow runs are titled "Desktop - START · <username> · <os>" (run-name in
// the workflows; the API returns it as display_title - name is always the
// bare workflow name). The panel used to show the newest desktop run of ANY
// user, so right after clicking Start a user saw someone else's finished run
// with every step "done". Match the username as a whole " · "-separated token
// so "mnuowr" never claims "mnuowr-2", match the action (START vs DESTROY) so
// a cancel never shows the start run, and ignore runs from before this action.
// dispatched_at is written before the dispatch call, so 30 s covers clock skew.
export function runBelongsTo(run, username, sinceTs, verb) {
  const parts = String(run?.display_title || "").split(" · ");
  const head = parts[0].toUpperCase();
  if (!head.startsWith("DESKTOP")) return false;
  if (verb && !head.endsWith(` ${verb}`)) return false;
  if (!parts.slice(1).includes(String(username))) return false;
  if (sinceTs && Date.parse(run.created_at) / 1000 < Number(sinceTs) - 30) return false;
  return true;
}

// Mumbai stays the default so every running session (and the state key that
// tracks it, see dispatch.js) keeps working unchanged.
export const REGIONS = {
  "ap-south-1": { az: "c", label: "India (Mumbai)" },
  // me-central-1 (UAE) was here 2026-09-12/13 and is removed: AWS throttles
  // RunInstances in ALL its zones for this account ("operational issue",
  // seen in August and again 2026-09-12). Re-add once a launch there works.
};

// One region: India (ap-south-1). UAE was removed 2026-09-13 (AWS throttles
// every launch there for this account) and the owner confirmed 2026-09-17
// that this app uses India only. Kept as a function, not a constant, because
// the session records the region it ran in and a second region would return
// here rather than in every caller.
export function requestedRegion(bodyRegion) {
  return Object.prototype.hasOwnProperty.call(REGIONS, bodyRegion) ? bodyRegion : "ap-south-1";
}

// What "the desktop answers" means per OS. Linux: Caddy serves /healthz.
// Windows: DCV serves its web client at / and has no health endpoint - a
// 200 there is the equivalent signal. Without this a Windows session would
// sit on "Booting..." forever after it was up.
export function probeUrl(url, os) {
  if (!url) return null;
  return os === "windows" ? `${url}/` : `${url}/healthz`;
}

export function desktopUrl(username) {
  return `https://${username}.${DESKTOP_DOMAIN}`;
}

// Short timeout on purpose. This runs inside a request that must finish well
// within the function limit, and a desktop needing more than 2.5s to answer a
// static 200 is not ready anyway.
export async function urlUp(probe, timeoutMs = 2500) {
  if (!probe) return false;
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await fetch(probe, { signal: ac.signal });
    return r.status === 200;
  } catch {
    return false;
  } finally {
    clearTimeout(t);
  }
}

export function activeCount(sessions) {
  return Object.values(sessions).filter((s) =>
    LIVE_STATUSES.includes(s.status)
  ).length;
}

// ready -> active once the desktop actually answers, and pending -> error if
// the start never reported back. Without the first, a session sits on
// "Booting..." forever after it is up; without the second, a failed run holds
// one of MAX_CONCURRENT slots indefinitely.
//
// Probes only the CALLER's own desktop, not every registered user. The hub
// probed everyone on every poll, which is what made its status endpoint take
// 13 seconds - and here it would blow the function time limit outright.
export async function refreshOwn(sessions, username, store) {
  const s = sessions[username];
  if (!s) return sessions;
  const now = Date.now() / 1000;
  if (s.status === "ready" && (await urlUp(probeUrl(s.url, s.os)))) {
    s.status = "active";
    await store.putSession(username, s);
    await store.putHealth(username, { checked_at: now });
  } else if (
    ["pending", "building", "waking"].includes(s.status) &&
    now - (s.dispatched_at || now) > PENDING_TIMEOUT_S
  ) {
    delete sessions[username];
    await store.dropSession(username);
  } else if (s.status === "active") {
    // Health is merged in for the page but written only to its own hash, so
    // this never overwrites the session itself (see state.js getHealth).
    let health = await store.getHealth(username);
    if (healthCheckDue({ ...s, ...health }, now)) {
      const { checked_at, unreachable_since } = applyHealth(health, await urlUp(probeUrl(s.url, s.os)), now);
      health = unreachable_since ? { checked_at, unreachable_since } : { checked_at };
      await store.putHealth(username, health);
    }
    sessions[username] = { ...s, ...health };
  }
  return sessions;
}
