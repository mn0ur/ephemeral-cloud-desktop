// Desktop liveness and session reconciliation.

export const DESKTOP_DOMAIN = process.env.DESKTOP_DOMAIN || "desktop.mnour.dev";
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

// The server-side policy for who may start Windows. The client only shows
// the selector to admins, but - as with persist - this is the enforcement
// point: anyone else asking for windows silently gets linux.
export function requestedOs(isAdmin, bodyOs) {
  return isAdmin === true && bodyOs === "windows" ? "windows" : "linux";
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
