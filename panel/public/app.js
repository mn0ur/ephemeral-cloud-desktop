// Control panel front end.
//
// A real .js file, deliberately. On the hub this lived inside a Python
// triple-quoted string, where a single "\n" I intended for JavaScript was
// consumed by Python instead - splitting a string literal across lines and
// taking the ENTIRE script down with one syntax error. The page still served,
// so it looked like a styling bug. In a plain file that class of mistake cannot
// happen, and the browser reports the line if anything else does.

const $ = (id) => document.getElementById(id);
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );

let session = null;
let busy = false;
let pendingAction = null;
let googleRendered = false;
// Set when a desktop became ready but the browser refused to open the tab for
// us, so the Running card can say so instead of the user seeing nothing happen.
let autoOpenBlocked = false;
// True from the moment WE dispatch a start until the resulting session either
// reaches "active" (auto-open fires) or disappears. Kept separate from `busy`
// so clearing busy early (see poll()) doesn't also skip the one auto-open.
let startedByMe = false;

function fmtDur(sec) {
  const m = Math.floor(sec / 60), h = Math.floor(m / 60);
  return h ? `${h}h ${m % 60}m` : `${m}m`;
}

// Real workflow steps, so a multi-minute start is followable rather than a
// spinner indistinguishable from a hang - and a failure names the step.
function stepsHtml(p) {
  if (!p?.steps?.length) return "";
  const icon = (st) =>
    st === "success" ? '<span class="s-ok">done</span>'
    : st === "failure" ? '<span class="s-bad">failed</span>'
    : st === "in_progress" ? '<span class="s-run">running</span>'
    : st === "skipped" ? '<span class="s-skip">skipped</span>'
    : '<span class="s-wait">waiting</span>';
  const rows = p.steps.map((s) => `<div class="step">${icon(s.state)}<span>${esc(s.name)}</span></div>`).join("");
  const failed = p.conclusion === "failure"
    ? '<div class="s-bad" style="margin-top:.4rem">This run failed &mdash; see the step marked failed.</div>' : "";
  const link = p.url ? `<a class="sub" href="${esc(p.url)}" target="_blank" rel="noopener">full log &rarr;</a>` : "";
  return `<div class="steps"><div class="sub">${esc(p.name)} &middot; ${esc(p.status)}</div>${rows}${failed}${link}</div>`;
}

function renderMine(s) {
  const box = $("mine");
  if (!session) { box.innerHTML = ""; return; }

  // While an action we dispatched is in flight, hold that state regardless of
  // whether the session exists yet. Without this the next poll draws the plain
  // Start button over "Starting..."/"Destroying...", so every action looks
  // ignored - and a destroy gets clicked repeatedly.
  if (busy) {
    box.innerHTML =
      `<div><span class="dot work"></span> ${pendingAction === "destroy" ? "Destroying&hellip;" : "Starting&hellip;"}</div>` +
      `<div class="sub">${pendingAction === "destroy"
        ? "Terminating the instance. Your files are kept if you chose to keep them."
        : "This takes a few minutes."}</div>` + stepsHtml(s.progress);
    return;
  }

  const mine = s.my_session;
  if (!mine || mine.status === "error") {
    // Delete-saved-data appears only when there is some and nothing is running.
    // Deliberately not beside Destroy: destroy ends a session and KEEPS your
    // files, this throws them away. Side by side is how someone deletes their
    // work from muscle memory.
    const dataBlock = s.has_saved_data ? `
      <div class="steps">
        <div class="sub">You have saved files from a previous session. They are restored on your next start.</div>
        <div class="row"><button id="wipe" class="stop">Delete my saved data</button></div>
      </div>` : "";
    const persistLabel = session.can_persist
      ? `<label><input type="checkbox" id="persist"> Keep my files after destroy</label>`
      : "";
    box.innerHTML = `
      ${persistLabel}
      <div class="row"><button id="start" class="go">Start my desktop</button></div>
      ${dataBlock}`;
    $("start").onclick = () => go("start");
    if ($("wipe")) $("wipe").onclick = wipeData;
    return;
  }

  const running = mine.status === "active";
  let html = `<div><span class="dot ${running ? "up" : "work"}"></span> ${running ? "Running" : "Booting&hellip;"}`;
  if (running && mine.started_at) {
    const secs = Date.now() / 1000 - mine.started_at;
    html += ` <span class="sub">&middot; ${fmtDur(secs)} &middot; ~$${((secs / 3600) * (s.hourly_usd || 0.0529)).toFixed(2)} this session</span>`;
  }
  if (mine.expires_at) {
    const left = mine.expires_at - Date.now() / 1000;
    html += ` <span class="sub">&middot; ${left > 0 ? fmtDur(left) + " left" : "ending&hellip;"}</span>`;
  }
  html += "</div>";

  // Username AND password together: the desktop asks for both, and the username
  // is derived from the Google account rather than chosen, so it is not
  // guessable by the person using it.
  html += `<div class="creds">
      <div><span class="ck">username</span><span class="cv">${esc(session.user_id)}</span></div>
      ${mine.password
        ? `<div><span class="ck">password</span><span class="cv">${esc(mine.password)}</span></div>`
        : '<div class="sub">Password not recorded &mdash; this desktop was recovered rather than started normally.</div>'}
      <div class="sub" style="margin-top:.35rem">Same username every time. The password changes each start.</div>
    </div>`;

  if (running && autoOpenBlocked) {
    html += `<div class="steps" style="border-color:var(--green-dim)">
        <div><span class="dot up"></span> <strong>Your desktop is ready.</strong></div>
        <div class="sub">The browser blocked the tab we tried to open for you &mdash; use the button below. Keep this page open: the desktop asks for the username and password shown here.</div>
      </div>`;
  }
  if (mine.url) html += `<a class="open" href="${esc(mine.url)}" target="_blank" rel="noopener">Open desktop &rarr;</a>`;
  html += '<div class="row"><button id="destroy" class="stop">Destroy</button></div>';
  if (!running) html += stepsHtml(s.progress);
  box.innerHTML = html;
  $("destroy").onclick = () => go("destroy");
}

async function go(action) {
  const body = { action };
  if (action === "start") body.persist = $("persist")?.checked || false;
  if (action === "destroy" && !confirm("Destroy your desktop? Your files survive only if you chose to keep them.")) return;
  $("err").textContent = "";
  busy = true; pendingAction = action;
  if (action === "start") startedByMe = true;
  renderMine({ progress: null });
  try {
    const r = await fetch("/api/dispatch", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    if (!r.ok) { busy = false; pendingAction = null; $("err").textContent = (await r.json()).error || await r.text(); }
  } catch (e) { busy = false; pendingAction = null; $("err").textContent = e.message; }
}

async function wipeData() {
  // Two steps, because this is irreversible with no snapshot behind it and a
  // single click-through is too cheap for permanently deleting someone's files.
  if (!confirm("Permanently delete your saved files?\n\nThis cannot be undone. Your next desktop starts clean.")) return;
  if (prompt("This is irreversible. Type DELETE to confirm:") !== "DELETE") {
    $("err").textContent = "Not deleted - confirmation did not match."; return;
  }
  $("err").textContent = "";
  try {
    const r = await fetch("/api/dispatch", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "wipe" }),
    });
    if (!r.ok) { $("err").textContent = (await r.json()).error || await r.text(); return; }
    $("mine").innerHTML = '<div><span class="dot work"></span> Deleting your saved data&hellip;</div>';
  } catch (e) { $("err").textContent = e.message; }
}

function onGoogleCredential(resp) {
  $("err").textContent = "";
  $("g-wrap").innerHTML = '<div class="sub">Signing in&hellip;</div>';
  fetch("/api/google-login", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ credential: resp.credential }),
  })
    .then((r) => { if (!r.ok) throw new Error("sign-in rejected"); return r.json(); })
    // Reload rather than waiting for the next poll. Google's button keeps its
    // own state, and relying on the poll made a successful sign-in look like
    // nothing had happened until the tab was closed and reopened.
    .then(() => location.reload())
    .catch((e) => { $("err").textContent = e.message; poll(); });
}

async function poll() {
  try {
    const s = await (await fetch("/api/status", { cache: "no-store" })).json();
    if (s.error) $("err").textContent = s.error;

    if (s.google_client_id && !googleRendered && window.google?.accounts?.id) {
      googleRendered = true;
      google.accounts.id.initialize({ client_id: s.google_client_id, callback: onGoogleCredential });
      google.accounts.id.renderButton($("g-wrap"), { theme: "filled_black", size: "large" });
    }
    $("g-disabled").style.display = s.google_client_id ? "none" : "block";

    session = s.session || null;
    $("g-wrap").style.display = session ? "none" : (s.google_client_id ? "flex" : "none");
    $("g-signed").style.display = session ? "flex" : "none";
    if (session) $("g-email").textContent = session.email;

    // Clear the client-side "Starting..." overlay the moment the session
    // actually exists server-side (status "pending" or "ready"), NOT only
    // once it reaches "active". Those two used to be the same condition,
    // which meant the page sat on a bare "Starting..." spinner for the
    // entire multi-minute container boot - even though the booting card
    // with real credentials was available the whole time - and only a
    // manual refresh (which resets `busy` to its default) ever revealed it.
    if (busy && pendingAction === "start" && s.my_session && s.my_session.status !== "error") {
      busy = false; pendingAction = null;
    }
    if (busy && pendingAction === "destroy" && !s.my_session) { busy = false; pendingAction = null; }

    // Auto-open is separate from clearing busy above, and fires exactly once
    // per session becoming active - tracked on the session object itself so
    // it survives busy already being false by the time healthz passes.
    //
    // A NEW TAB, not location.href: the desktop's login prompt asks for the
    // username/password shown on THIS page. Navigating this tab away took the
    // credentials off screen at the exact moment they were needed, leaving
    // the login prompt with no way to answer it. Falling through to
    // renderMine() below keeps this tab on the "Running" card with creds
    // visible, whichever tab the user actually looks at.
    if (startedByMe && s.my_session?.status === "active") {
      startedByMe = false;
      // window.open() here runs from a TIMER, not a click, so it is not a user
      // gesture - and popup blockers refuse those, returning null, silently.
      // The desktop was ready and the page appeared to do nothing at all.
      // Capture the refusal so the card below can show a real call to action.
      let opened = null;
      try { opened = window.open(s.my_session.url, "_blank", "noopener"); } catch { /* blocked */ }
      autoOpenBlocked = !opened;
    }
    if (!s.my_session) startedByMe = false;

    renderMine(s);
  } catch (e) {
    $("err").textContent = "status unreachable: " + e.message;
  }
}

$("g-signout").onclick = () => {
  // disableAutoSelect stops Google silently re-issuing a credential for the same
  // account, which made signing out look like it had not worked.
  try { google.accounts.id.disableAutoSelect(); } catch { /* not loaded yet */ }
  fetch("/api/google-logout", { method: "POST" }).then(() => location.reload());
};

poll();
setInterval(poll, 5000);

// Coming back to this tab must be equivalent to reloading it.
//
// A desktop takes minutes to become ready, so nobody sits and watches the
// page - they switch away and come back. Mobile browsers THROTTLE, and often
// entirely FREEZE, setInterval in a backgrounded tab, so the 5s poll that
// would have noticed "ready" never ran. The page was still showing
// "Starting..." with no username or password, and only a manual refresh fixed
// it - which is exactly the reported symptom.
//
// Both events, deliberately: visibilitychange covers tab switches and locking
// the phone, focus covers window-level switches that fire no visibility
// change. poll() is idempotent, so a doubled call is harmless.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) poll();
});
window.addEventListener("focus", () => poll());
