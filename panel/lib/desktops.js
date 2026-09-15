// Desktop liveness and session reconciliation.

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
// Windows on the same instance class is ~2x: the Windows licence is priced
// per vCPU and spot does not discount it. m6i.large (2 vCPU) Windows spot in
// ap-south-1, measured 2026-09-11. Keep in step with
// terraform/variables.tf instance_type_windows.
export const HOURLY_USD_WINDOWS = Number(process.env.HOURLY_USD_WINDOWS || 0.204);
export const PENDING_TIMEOUT_S = 10 * 60;

export function hourlyRate(os) {
  return os === "windows" ? HOURLY_USD_WINDOWS : HOURLY_USD;
}

// Every tier chooses its OS at Start (owner decision 2026-09-15: guests,
// permanent users and admins alike). Guests stay cost-capped by the reaper's
// time limit. Exact match only - anything that is not the string "windows"
// is linux, so a malformed body can never select something unexpected.
export function requestedOs(bodyOs) {
  return bodyOs === "windows" ? "windows" : "linux";
}

// What the user's session IS, from their point of view. Derived on the server
// so the page never has to guess from raw fields - it guessed wrong: a
// just-dispatched start (status "pending", no password yet) was drawn as an
// existing machine with "Password not recorded - this desktop was recovered",
// and a new user destroyed their own start twice believing a machine had
// already been running before they arrived (2026-09-15).
export function sessionPhase(s) {
  if (!s) return null;
  if (s.destroy_dispatched_at) return "destroying";
  if (s.status === "error") return "error";
  if (s.status === "active") return "running";
  if (s.status === "ready") return "booting";
  return "starting";
}

// The first minute of a start offers no Cancel: a destroy dispatched then
// only queues behind the apply anyway, and an immediate Cancel is almost
// always a misread of the screen, not an intent.
export const CANCEL_AFTER_S = 60;

export function canCancel(s, now = Date.now() / 1000) {
  const phase = sessionPhase(s);
  if (phase === "booting" || phase === "running") return true;
  if (phase === "starting") return now - (Number(s.dispatched_at) || 0) >= CANCEL_AFTER_S;
  return false;
}

// Workflow runs are named "Desktop - START · <username> · <os>" (run-name in
// the workflows). The panel used to show the newest desktop run of ANY user,
// so right after clicking Start a user saw someone else's finished run with
// every step "done". Match the username as a whole " · "-separated token so
// "mnuowr" never claims "mnuowr-2", and ignore runs from before this action.
export function runBelongsTo(run, username, sinceTs) {
  const name = String(run?.name || "");
  const parts = name.split(" · ");
  if (!parts[0].toUpperCase().startsWith("DESKTOP")) return false;
  if (!parts.slice(1).includes(String(username))) return false;
  if (sinceTs && Date.parse(run.created_at) / 1000 < Number(sinceTs) - 120) return false;
  return true;
}

// Mumbai stays the default so every running session (and the state key that
// tracks it, see dispatch.js) keeps working unchanged. UAE AMIs are being
// baked in parallel - az matches terraform/variables.tf's az_suffix default
// per region.
export const REGIONS = {
  "ap-south-1": { az: "c", label: "India (Mumbai)" },
  // me-central-1 (UAE) was here 2026-09-12/13 and is removed: AWS throttles
  // RunInstances in ALL its zones for this account ("operational issue",
  // seen in August and again 2026-09-12). Re-add once a launch there works.
};

// Same shape as requestedOs: admin-only, server is the actual enforcement
// point, the client selector is only a hint.
export function requestedRegion(isAdmin, bodyRegion) {
  return isAdmin === true && Object.prototype.hasOwnProperty.call(REGIONS, bodyRegion)
    ? bodyRegion
    : "ap-south-1";
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
    ["pending", "ready", "active"].includes(s.status)
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
export async function refreshOwn(sessions, username, put, drop) {
  const s = sessions[username];
  if (!s) return sessions;
  if (s.status === "ready" && (await urlUp(probeUrl(s.url, s.os)))) {
    s.status = "active";
    await put(username, s);
  } else if (
    s.status === "pending" &&
    Date.now() / 1000 - (s.dispatched_at || Date.now() / 1000) > PENDING_TIMEOUT_S
  ) {
    delete sessions[username];
    await drop(username);
  }
  return sessions;
}
