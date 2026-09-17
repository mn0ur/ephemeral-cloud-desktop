import { sessionFromRequest, GOOGLE_CLIENT_ID } from "../lib/auth.js";
import {
  loadSessions, putSession, dropSession, hasSavedData, stateConfigured, getNotice, getHealth, putHealth,
  loadMachines, putMachine, claimOnce,
} from "../lib/state.js";
import { dispatch, WORKFLOWS, runProgress, tokenConfigured } from "../lib/github.js";
import {
  refreshOwn, activeCount, MAX_CONCURRENT, HOURLY_USD, HOURLY_USD_WINDOWS, DESKTOP_DOMAIN, REGIONS,
  sessionPhase, canCancel, hourlyRate,
} from "../lib/desktops.js";
import { missingOses, machineKey, MACHINE_OSES } from "../lib/machines.js";

export default async function handler(req, res) {
  // Never cached: the page polls this to decide what to render, and a cached
  // response would show a desktop as running after it was destroyed.
  res.setHeader("Cache-Control", "no-store");

  if (!stateConfigured) {
    return res.status(200).json({
      error:
        "No KV store attached to this project. Create one in Vercel > Storage and connect it, then redeploy.",
      google_client_id: GOOGLE_CLIENT_ID,
      session: null,
      sessions: {},
    });
  }

  const session = await sessionFromRequest(req);
  let sessions = await loadSessions();

  if (session) {
    sessions = await refreshOwn(sessions, session.user_id, { putSession, dropSession, getHealth, putHealth });
  }

  // A permanent user's two machines are built the first time they sign in, so
  // that even their first Start is a ~1 minute wake rather than a ~3 minute
  // build. Each build is claimed once (build:<user>:<os>), so a refresh or a
  // second tab cannot start duplicates - and on every poll AFTER the first,
  // the claim just fails fast and nothing is dispatched at all. That claim
  // has a different key from the start:<user> claim in api/dispatch.js, so
  // the two never contend for the same lock: a sign-in build and a manual
  // Start of the OTHER os could in principle race, but startPlan/session-ready
  // already treat "machine already building" as adopt, not a second build.
  //
  // This runs inside the 5s status poll under a 10s function limit
  // (vercel.json), so the two dispatches (at most one per OS) are fired
  // together with Promise.allSettled rather than one after another - a slow
  // GitHub API then costs one round trip's worth of latency, not two, and it
  // costs that only on the single poll that wins each claim.
  let hasMachines = false;
  let myMachines = null;
  if (session?.has_access) {
    const machines = await loadMachines();
    // Tombstones excluded: a user whose only records are deleted machines has
    // nothing to wake, and telling them "Ready in about a minute" in front of
    // a 3-minute rebuild is a lie the page then has to walk back.
    hasMachines = MACHINE_OSES.some((os) => {
      const mine = machines[machineKey(session.user_id, os)];
      return Boolean(mine) && mine.state !== "deleted";
    });
    // The caller's OWN machines, so the Start card can list what is parked
    // and offer to delete it. State, os and hostname only - never a password,
    // never a token, and never another user's machine.
    myMachines = {};
    for (const os of MACHINE_OSES) {
      const mine = machines[machineKey(session.user_id, os)];
      if (!mine || mine.state === "deleted") continue;
      myMachines[os] = { os, state: mine.state || null, hostname: mine.hostname || null };
    }
    const own = sessions[session.user_id];
    // The machine payload above is pure bookkeeping and costs nothing; the
    // sign-in BUILD needs a GitHub token, so only that half is skipped when
    // the deployment has none.
    if (tokenConfigured) await Promise.allSettled(
      missingOses(machines, session.user_id).map(async (os) => {
        // A manual Start (api/dispatch.js) also writes status "building" for
        // its os BEFORE any machine record exists - the record is only
        // written by session-ready once the build finishes. Without this
        // check that in-flight manual build would look exactly like a
        // "missing machine" to this loop too, on every poll until the
        // record appears, and get built a second time. dispatch.js's
        // start:<user> claim does not protect against this - it is released
        // as soon as that handler returns, long before the build completes.
        //
        // The remaining window - `sessions` was snapshotted at the top of
        // this handler and a manual Start could land between that snapshot
        // and the claimOnce below - is accepted, not closed: both claim keys
        // (start:<user> and build:<user>:<os>) are deliberately disjoint (see
        // the block comment above), and the gap is a few lines of synchronous
        // JS wide, several orders of magnitude narrower than the minutes-long
        // "building" window this check already closes.
        if (own?.os === os && own?.status === "building") return;
        const claim = `build:${session.user_id}:${os}`;
        // 120s, not the machine's own minutes-long build time: this claim's
        // job is only to stop the NEXT 5-second poll from re-dispatching
        // while a dispatch is in flight or just failed. On SUCCESS the claim
        // never needs releasing either - putMachine below makes missingOses
        // stop returning this os on the very next poll, which is a stronger
        // guard than the claim. On FAILURE (e.g. a GitHub outage) the claim
        // is deliberately left to expire on its own: releasing it here would
        // turn a GitHub outage into a dispatch attempt every 5 seconds for as
        // long as the outage lasts, one per user+OS; leaving it held turns
        // that into a natural ~2-minute backoff instead.
        if (!(await claimOnce(claim, 120))) return;
        try {
          await dispatch(WORKFLOWS.start, {
            username: session.user_id, guest_username: session.user_id,
            owner_email: session.email, fresh: "false", persist: "true",
            is_guest: "false", use_spot: "false", os, region: "ap-south-1",
          });
          await putMachine(session.user_id, os, {
            os, state: "building",
            created_at: Date.now() / 1000,
            // When this build started, so a build that never calls back can
            // be recognised as dead (staleBuild in lib/machines.js) and so
            // dispatch.js's adopt branch can anchor the "building" card on
            // the real start time rather than on the moment Start was pressed.
            building_since: Date.now() / 1000,
          });
        } catch (e) {
          console.error("sign-in build failed", os, e.message);
        }
      })
    );
  }

  // Non-admins see only their own session. Never anyone else's email, URL or
  // password - the admin view is the only place those appear.
  const visible = {};
  for (const [uname, s] of Object.entries(sessions)) {
    const mine = session && session.user_id === uname;
    if (session && (mine || session.is_admin)) {
      const { lost_token_hash: _h, ...pub } = s;
      visible[uname] = pub;
    }
  }

  // The page renders from `phase` - never from raw status - so a start that
  // has not produced a machine yet can never be drawn as an existing one.
  const own = session ? sessions[session.user_id] || null : null;
  const phase = sessionPhase(own);
  // lost_token_hash stays server-side; the page never needs it.
  const { lost_token_hash: _h, ...ownPublic } = own || {};
  const mine = own ? { ...ownPublic, phase, can_cancel: canCancel(own), hourly_usd: hourlyRate(own.os, own.market) } : null;
  // Progress is the caller's OWN run for the action in flight, anchored on
  // when that action was dispatched; nobody else's run is ever shown here.
  const worthProgress = Boolean(session) && ["starting", "booting", "destroying"].includes(phase);
  const anchor = phase === "destroying" ? own?.destroy_dispatched_at : own?.dispatched_at;

  const out = {
    google_client_id: GOOGLE_CLIENT_ID,
    session,
    my_session: mine,
    sessions: visible,
    active_count: activeCount(sessions),
    max_concurrent: session?.is_admin ? MAX_CONCURRENT : null,
    desktop_domain: DESKTOP_DOMAIN,
    hourly_usd: HOURLY_USD,
    hourly_usd_windows: HOURLY_USD_WINDOWS,
    regions: REGIONS,
    // Two GitHub API calls - only when something is actually mid-flight. A
    // settled panel has nothing to report, and polling the Actions API every
    // few seconds forever would burn rate limit for no reason.
    progress: worthProgress ? await runProgress(session.user_id, anchor, phase === "destroying" ? "DESTROY" : "START") : null,
    has_saved_data: session ? await hasSavedData(session.user_id) : false,
    has_machines: hasMachines,
    // Only ever the caller's own, and only non-secret fields - see above.
    machines: myMachines,
    notice: session && (!own || phase === "error") ? await getNotice(session.user_id) : null,
  };

  if (!tokenConfigured) {
    out.error =
      "No GH_TOKEN set on this deployment. Buttons are inert until it is added in Vercel > Settings > Environment Variables.";
  }

  return res.status(200).json(out);
}
