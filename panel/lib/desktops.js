// Desktop liveness and session reconciliation.

export const DESKTOP_DOMAIN = process.env.DESKTOP_DOMAIN || "desktop.mnour.dev";
export const MAX_CONCURRENT = Number(process.env.MAX_CONCURRENT || 5);
export const HOURLY_USD = Number(process.env.HOURLY_USD || 0.104);
export const PENDING_TIMEOUT_S = 10 * 60;

export function desktopUrl(username) {
  return `https://${username}.${DESKTOP_DOMAIN}`;
}

// Short timeout on purpose. This runs inside a request that must finish well
// within the function limit, and a desktop needing more than 2.5s to answer a
// static 200 is not ready anyway.
export async function urlUp(url, timeoutMs = 2500) {
  if (!url) return false;
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await fetch(`${url}/healthz`, { signal: ac.signal });
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
  if (s.status === "ready" && (await urlUp(s.url))) {
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
