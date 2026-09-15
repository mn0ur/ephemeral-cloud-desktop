import { loadSessions, putSession, logEvent, setNotice, claimOnce, releaseClaim } from "../lib/state.js";
import { dispatch, WORKFLOWS } from "../lib/github.js";
import { tokenMatches } from "../lib/desktops.js";

// Called by the desktop MACHINE itself when AWS gives it the two-minute spot
// reclaim warning (terraform/user-data.sh.tpl, desktop-reclaim-watch).
//
// Without this, a reclaimed machine left the panel showing "Running" with an
// Open button onto nothing, plus a DNS record and security group behind it,
// until someone clicked Destroy (2026-09-15).
//
// Authenticated by the per-session token desktop-up.yml generated for that one
// machine - never the hub callback secret, which must not sit on a machine the
// user controls. The token can only do this one thing, to this one session:
// run the same cleanup the user's own Destroy button runs.
export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });

  const s = (await loadSessions())[username];
  if (!s || !tokenMatches(req.body?.token, s.lost_token_hash)) {
    return res.status(403).json({ error: "not this session" });
  }
  if (s.destroy_dispatched_at) return res.status(200).json({ ok: true, already: true });

  // The watcher retries and requests can overlap; exactly one cleanup runs.
  // Keyed on the token hash, so a later session's own reclaim is never
  // mistaken for this one.
  const claim = `lost:${username}:${s.lost_token_hash.slice(0, 16)}`;
  if (!(await claimOnce(claim, 900))) return res.status(200).json({ ok: true, already: true });

  try {
    await dispatch(WORKFLOWS.destroy, {
      confirm: "DESTROY",
      guest_username: username,
      os: s.os || "linux",
      region: s.region || "ap-south-1",
    });
  } catch (e) {
    // Let the watcher's next retry try again.
    await releaseClaim(claim);
    return res.status(502).json({ error: "could not start cleanup" });
  }
  const now = Date.now() / 1000;
  await putSession(username, { ...s, destroy_dispatched_at: now, lost_at: now });
  await setNotice(
    username,
    "AWS took back your last desktop because it ran out of spare capacity. Your saved files are safe - start again whenever you're ready."
  );
  await logEvent("reclaimed", { username, email: s.email, os: s.os, market: s.market });
  return res.status(200).json({ ok: true });
}
