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

// The desktop's login is HTTP Basic Auth (linuxserver/webtop's embedded
// nginx), which technically still needs a username - but the browser never
// has to ask for one. Basic Auth credentials embedded in the URL itself
// (https://user:pass@host/) are accepted by every mainstream browser on a
// direct top-level navigation, which is exactly how this link is opened
// (window.open / a plain <a>, never an iframe). So "log in with only the
// password" is real, not just a UI simplification: the username still
// travels, just never in front of the person copying anything.
function loginUrl(url, user, pass) {
  if (!url || !user || !pass) return url;
  try {
    const u = new URL(url);
    u.username = user;
    u.password = pass;
    return u.toString();
  } catch {
    return url; // malformed URL - fall back rather than hand back garbage
  }
}

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
// The phase last drawn, so Destroy/Cancel can confirm with the right words.
let lastPhase = null;


// Measured, not guessed (2026-09-12/13, ap-south-1): Windows Start->ready
// 186-189s, Linux ~325s, destroy 105-140s. The bar fills to 95% at the
// expected time and then HOLDS with "taking longer" - it never claims 100%
// before the real state change arrives from the poll.
// MEASURED on real machines, not guessed (2026-09-17, sddtest, ap-south-1):
// a Linux wake took 101s from dispatch to the desktop answering with a valid
// certificate, and a sleep took 49s. Windows is not measured yet - it is the
// Linux figure plus the margin its slower boot has shown everywhere else.
// A bar that promises less than the truth reads as a hang, so these are
// rounded UP from the measurement.
const EXPECTED_S = { linux: 330, windows: 200, destroy: 135, wake_linux: 105, wake_windows: 150, sleep: 60 };
// Client-side anchor for the moment we clicked, used until the server-side
// timestamp (dispatched_at / destroy_dispatched_at) is on the session.
let actionStartedAt = null;

function barHtml(kind, startTs, extraClass = "") {
  const total = EXPECTED_S[kind] || EXPECTED_S.linux;
  const start = Number(startTs) || Date.now() / 1000;
  return `<div class="bar-wrap ${extraClass}" data-bar="${kind}" data-start="${start}" data-total="${total}">
      <div class="bar-track"><div class="bar-fill" style="width:0%"></div></div>
      <div class="bar-meta"><span class="bar-label"></span><span class="bar-eta"></span></div>
    </div>`;
}

function tickBars() {
  const now = Date.now() / 1000;
  document.querySelectorAll("[data-bar]").forEach((el) => {
    const total = Number(el.dataset.total), elapsed = Math.max(0, now - Number(el.dataset.start));
    const frac = Math.min(elapsed / total, 1);
    const pct = elapsed >= total ? 95 : Math.round(frac * 95);
    el.querySelector(".bar-fill").style.width = pct + "%";
    const left = Math.ceil((total - elapsed) / 60);
    const kind = el.dataset.bar;
    const verb = kind === "destroy" ? "Shutting down"
      : kind === "sleep" ? "Putting to sleep"
      : kind.startsWith("wake_") ? "Waking"
      : "Setting up";
    el.querySelector(".bar-label").textContent = elapsed >= total
      ? `${verb} — taking a little longer than usual`
      : `${verb} — usually about ${Math.round(total / 60)} min`;
    el.querySelector(".bar-eta").textContent = elapsed >= total ? "" : (left <= 1 ? "under a minute left" : `about ${left} min left`);
  });
}
setInterval(tickBars, 1000);

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
    const isShutdown = pendingAction === "destroy" || pendingAction === "delete";
    const isSleep = pendingAction === "sleep";
    box.innerHTML =
      `<div class="status"><span class="dot work"></span> ${isShutdown ? "Shutting down your desktop&hellip;" : isSleep ? "Putting your desktop to sleep&hellip;" : "Starting your desktop&hellip;"}</div>` +
      `<div class="sub">${isShutdown
        ? "Terminating the instance. Your files are kept."
        : isSleep
        ? "Everything on it is kept. Starting it again takes about a minute."
        : "We're creating a fresh machine for you."}</div>` +
      barHtml(isShutdown || isSleep ? "destroy" : ($("os")?.value || s.my_session?.os || "linux"),
        (isShutdown ? s.my_session?.destroy_dispatched_at : isSleep ? s.my_session?.sleep_dispatched_at : s.my_session?.dispatched_at) || actionStartedAt) +
      stepsHtml(s.progress);
    tickBars();
    return;
  }

  const mine = s.my_session;
  if (!mine || mine.phase === "error" || mine.status === "error") {
    lastPhase = null;
    // Guests removed 2026-09-17: everyone who can start keeps their files, so
    // there is no choice to offer. An account without access gets told so
    // plainly instead of a button that would fail.
    if (!session.has_access) {
      box.innerHTML =
        '<div class="status"><span class="dot"></span> No access yet</div>' +
        '<div class="sub">Your account isn\'t enabled for Sihaab yet. Ask the owner to add you, then sign in again.</div>';
      return;
    }
    // Delete-saved-data appears only when there is some and nothing is running.
    // Deliberately not beside Destroy: destroy ends a session and KEEPS your
    // files, this throws them away. Side by side is how someone deletes their
    // work from muscle memory.
    const dataBlock = s.has_saved_data ? `
      <div class="steps">
        <div class="sub">You have saved files from a previous session. They are restored on your next start.</div>
        <div class="row"><button id="wipe" class="stop">Delete my saved data</button></div>
      </div>` : "";
    // Every tier picks the OS for the machine it is about to create. Nothing
    // is running until this Start button is pressed.
    const osSelect = `<label>Operating system <select id="os"><option value="linux">Linux</option><option value="windows">Windows</option></select></label>`;
    // No region selector: only one region is offered (ap-south-1). The
    // server still records and enforces region; re-add a selector when a
    // second region actually works (see REGIONS in lib/desktops.js).
    // e.g. "AWS took back your last desktop" (api/session-lost.js). Cleared
    // server-side on the next Start.
    const noticeBlock = s.notice ? `<div class="steps"><div class="sub">${esc(s.notice)}</div></div>` : "";
    // A machine that is asleep has no session at all, so this Start card is
    // exactly what a user with parked machines sees - the sub-text must say
    // so, not imply a from-scratch build that no longer happens.
    const startSub = s.has_machines
      ? '<div class="sub">Ready in about a minute.</div>'
      : '<div class="sub">Setting up your first desktop takes about 3 minutes.</div>';
    // A parked machine has no session, so this Start card is the ONLY screen
    // it ever appears on - and until it was listed here it could not be
    // deleted at all, quietly costing its disk (~$4/month Windows, ~$2.50
    // Linux) forever. Server sends state, os and hostname only; no secret of
    // any kind, and never another user's machine.
    const machineRows = Object.values(s.machines || {})
      .map((m) => {
        const label = m.os === "windows" ? "Windows" : "Linux";
        const state = m.state === "sleeping" ? "asleep"
          : m.state === "running" ? "running"
          : m.state === "building" ? "being set up"
          : m.state === "deleting" ? "being deleted"
          : esc(m.state || "unknown");
        // "being deleted" keeps its Delete, deliberately: if the destroy
        // workflow failed, the record stays "deleting" forever and Start
        // adopts it and does nothing - pressing Delete again re-dispatches
        // the destroy, which is the user's only way out of that.
        const canDelete = true;
        return `<div class="row machine-row">
            <span>${label} &middot; <span class="sub">${state}</span></span>
            ${canDelete ? `<button type="button" class="stop machine-del" data-os="${esc(m.os)}">Delete</button>` : ""}
          </div>`;
      })
      .join("");
    const machineBlock = machineRows
      ? `<div class="steps"><div class="sub">Your machines</div>${machineRows}
          <div class="sub">Deleting one frees its disk. Your saved files are kept.</div></div>`
      : "";
    box.innerHTML = `
      ${noticeBlock}
      ${osSelect}
      <div class="row"><button id="start" class="go">Start my desktop</button></div>
      ${startSub}
      ${machineBlock}
      ${dataBlock}`;
    $("start").onclick = () => go("start");
    box.querySelectorAll(".machine-del").forEach((b) => {
      b.onclick = () => go("delete", { os: b.dataset.os });
    });
    if ($("wipe")) $("wipe").onclick = wipeData;
    return;
  }

  // Render from the server's phase (lib/desktops.js sessionPhase), never from
  // raw fields. A start that has not produced a machine yet used to be drawn
  // as an existing machine - "Booting", a Destroy button, and "Password not
  // recorded - this desktop was recovered" - and a new user destroyed their
  // own start twice believing a machine was already running (2026-09-15).
  const phase = mine.phase || (mine.destroy_dispatched_at ? "destroying"
    : mine.status === "active" ? "running" : mine.status === "ready" ? "booting" : "starting");
  lastPhase = phase;
  const isWin = mine.os === "windows";
  const osLabel = isWin ? "Windows" : "Linux";

  if (phase === "starting") {
    let html = `<div class="status"><span class="dot work"></span> Starting your ${osLabel} desktop&hellip;</div>` +
      '<div class="sub">We\'re creating a fresh machine for you. Your sign-in details appear here as soon as it\'s ready.</div>' +
      barHtml(isWin ? "windows" : "linux", mine.dispatched_at);
    // No Cancel for the first minute (server decides: mine.can_cancel).
    if (mine.can_cancel) html += '<div class="row"><button id="destroy" class="stop">Cancel</button></div>';
    html += stepsHtml(s.progress);
    box.innerHTML = html;
    tickBars();
    if ($("destroy")) $("destroy").onclick = () => go("destroy");
    return;
  }

  if (phase === "destroying") {
    box.innerHTML =
      `<div class="status"><span class="dot work"></span> Shutting down your ${osLabel} desktop&hellip;</div>` +
      '<div class="sub">Your files are kept.</div>' +
      barHtml("destroy", mine.destroy_dispatched_at) + stepsHtml(s.progress);
    tickBars();
    return;
  }

  if (phase === "unreachable") {
    box.innerHTML =
      `<div class="status"><span class="dot down"></span> Not responding &middot; ${osLabel}</div>` +
      '<div class="sub">Your desktop has stopped answering for a few minutes. AWS may have taken the machine back. ' +
      'Destroy it to clean up &mdash; your saved files are kept &mdash; then start a new one.</div>' +
      (mine.url ? `<a class="open" href="${esc(isWin ? mine.url : loginUrl(mine.url, session.user_id, mine.password))}" target="_blank" rel="noopener">Try opening it anyway &rarr;</a>` : "") +
      '<div class="row"><button id="destroy" class="stop">Destroy</button></div>';
    $("destroy").onclick = () => go("destroy");
    return;
  }

  if (phase === "building") {
    let html = `<div class="status"><span class="dot work"></span> Setting up your ${osLabel} desktop for the first time&hellip;</div>` +
      '<div class="sub">This happens once. After this, starting it takes about a minute.</div>' +
      barHtml(isWin ? "windows" : "linux", mine.dispatched_at);
    // No Cancel for the first minute (same grace period as a plain start -
    // see canCancel). Cancelling a build removes the half-made machine, so
    // it dispatches "delete", not "destroy" - there is no session to sleep.
    if (mine.can_cancel) html += '<div class="row"><button id="cancel-build" class="stop">Cancel</button></div>';
    html += stepsHtml(s.progress);
    box.innerHTML = html;
    tickBars();
    if ($("cancel-build")) $("cancel-build").onclick = () => go("delete");
    return;
  }

  if (phase === "waking") {
    // No Cancel here, deliberately. A wake acts on a machine that ALREADY
    // exists and is full of the user's installed software, and the only thing
    // Cancel could dispatch is a delete - it offered to "remove the machine
    // being created" and would instead have destroyed their real one. A wake
    // is about a minute; there is nothing here worth cancelling.
    const html = `<div class="status"><span class="dot work"></span> Waking your ${osLabel} desktop&hellip;</div>` +
      '<div class="sub">Your files, apps and settings are exactly as you left them.</div>' +
      barHtml(isWin ? "wake_windows" : "wake_linux", mine.dispatched_at) +
      stepsHtml(s.progress);
    box.innerHTML = html;
    tickBars();
    return;
  }

  if (phase === "sleeping") {
    box.innerHTML =
      `<div class="status"><span class="dot work"></span> Putting your ${osLabel} desktop to sleep&hellip;</div>` +
      '<div class="sub">Everything on it is kept. Starting it again takes about a minute.</div>' +
      barHtml("sleep", mine.sleep_dispatched_at);
    tickBars();
    return;
  }

  // Every phase this file knows how to draw returns above. Anything else -
  // e.g. a cached older app.js talking to a newer server that has started
  // emitting a phase this build predates - must NOT fall through into the
  // running/booting card below: that card can render credentials and an
  // Open button for a machine that, for all this page actually knows, isn't
  // running at all.
  if (phase !== "booting" && phase !== "running") {
    box.innerHTML =
      '<div class="status"><span class="dot"></span> Your desktop\'s status is unavailable &mdash; reload the page.</div>';
    return;
  }

  // booting (machine exists, not answering yet) or running
  const running = phase === "running";
  let html = `<div class="status"><span class="dot ${running ? "up" : "work"}"></span> ${running ? "Running" : "Almost ready&hellip;"} &middot; ${osLabel}`;
  if (running && mine.started_at) {
    const secs = Date.now() / 1000 - mine.started_at;
    // Per session from the server: Windows and a Linux on-demand fallback cost more than Linux spot.
    const rate = mine.hourly_usd ?? (isWin ? s.hourly_usd_windows : s.hourly_usd);
    html += ` <span class="sub">&middot; ${fmtDur(secs)} &middot; ~$${((secs / 3600) * rate).toFixed(2)} this session</span>`;
  }
  html += "</div>";
  if (!running) html += barHtml(isWin ? "windows" : "linux", mine.dispatched_at);

  // Linux: Basic-Auth credentials ride in the URL (see loginUrl) so the link
  // logs straight in. Windows: DCV has its own sign-in page and ignores URL
  // credentials, so the link is plain and the card shows both fields.
  const openUrl = isWin ? mine.url : loginUrl(mine.url, session.user_id, mine.password);
  const loginUser = mine.login_user || session.user_id;
  html += `<div class="creds">
      ${isWin ? `<div><span class="ck">username</span><span class="cv">${esc(loginUser)}</span><button type="button" class="copy-btn" data-copy="${esc(loginUser)}" title="Copy username">&#128203;</button></div>` : ""}
      ${mine.password
        ? `<div><span class="ck">password</span><span class="cv">${esc(mine.password)}</span><button type="button" class="copy-btn" data-copy="${esc(mine.password)}" title="Copy password">&#128203;</button></div>
      <div class="sub" style="margin-top:.35rem">${isWin
        ? "Windows asks for these on its sign-in page. First start takes a little longer while your files drive is prepared."
        : "Opening the desktop below logs you straight in. Only copy this if it asks anyway, or you're opening it in a different browser."}</div>`
        : '<div class="sub">Password not recorded &mdash; this desktop was recovered rather than started normally.</div>'}
    </div>`;

  if (running && autoOpenBlocked) {
    html += `<div class="steps">
        <div><span class="dot up"></span> <strong>Your desktop is ready.</strong></div>
        <div class="sub">The browser blocked the tab we tried to open for you &mdash; use the button below.</div>
      </div>`;
  }
  // Open only once it actually answers - opening while it boots lands on an
  // error page and reads as broken.
  if (running && mine.url) html += `<a class="open" href="${esc(openUrl)}" target="_blank" rel="noopener">Open desktop &rarr;</a>`;
  html += '<div class="row"><button id="sleep" class="stop">End session</button></div>';
  html += '<div class="steps"><div class="sub">Ending a session keeps everything installed. ' +
    '<a href="#" id="delete">Delete this machine</a> to start over from a clean one.</div></div>';
  if (!running) html += stepsHtml(s.progress);
  box.innerHTML = html;
  tickBars();
  if ($("sleep")) $("sleep").onclick = () => go("sleep");
  if ($("delete")) $("delete").onclick = (e) => { e.preventDefault(); go("delete"); };
  box.querySelectorAll(".copy-btn").forEach((btn) => (btn.onclick = () => copyToClipboard(btn)));
}

// navigator.clipboard needs a secure context, which this page always is
// (HTTPS), but it's still wrapped: some in-app/webview browsers (notably on
// Android) omit or restrict it, and a silently-ignored click looks identical
// to a working one - so the fallback and the try/catch both matter here.
async function copyToClipboard(btn) {
  const text = btn.dataset.copy;
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    const original = btn.innerHTML;
    btn.innerHTML = "&#10003;";
    btn.classList.add("copied");
    setTimeout(() => { btn.innerHTML = original; btn.classList.remove("copied"); }, 1200);
  } catch {
    $("err").textContent = "Couldn't copy automatically - select the text and copy it by hand.";
  }
}

async function go(action, opts = {}) {
  const body = { action };
  if (action === "start") {
    body.os = $("os")?.value || "linux";
  }
  // A delete from the Start card names its machine explicitly: that machine
  // is parked, so there is no session for the server to read an OS from.
  if (action === "delete" && opts.os) body.os = opts.os;
  if (action === "destroy" && !confirm(lastPhase === "starting"
    ? "Cancel starting your desktop? The machine being created will be removed."
    : "Destroy your desktop? Your files are kept.")) return;
  // Three different deletes, three different truths to tell:
  //  - naming an OS (the Start card's parked-machine list): say WHICH machine,
  //    and that a replacement is a full 3-minute build, not a wake;
  //  - cancelling a BUILD: nothing is installed on it yet, so it is a cancel;
  //  - deleting the machine in the running card: the general wording.
  // A wake is no longer cancellable at all (see the waking card above).
  if (action === "delete" && opts.os) {
    const label = opts.os === "windows" ? "Windows" : "Linux";
    if (!confirm(
      `Delete your ${label} machine?\n\nAnything you installed on it is lost. Your saved files are kept, and a new ${label} machine takes about 3 minutes to build the next time you start one.`
    )) return;
  } else if (action === "delete" && lastPhase === "building") {
    if (!confirm("Cancel? The machine being created will be removed.")) return;
  } else if (action === "delete" && !confirm(
    "Delete this machine?\n\nAnything you installed on it is lost. Your saved files are kept, and a new machine is built next time you start (about 3 minutes)."
  )) return;
  if (action === "sleep" && !confirm(
    "End this session?\n\nEverything stays exactly as it is. Starting again takes about a minute."
  )) return;
  $("err").textContent = "";
  busy = true; pendingAction = action; actionStartedAt = Date.now() / 1000;
  startedByMe = action === "start"; // a cancel must not auto-open the machine it cancels
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
    if (busy && ["destroy", "delete", "sleep"].includes(pendingAction) && !s.my_session) { busy = false; pendingAction = null; }
    // Deleting a PARKED machine has no session to disappear - the server
    // writes one carrying the destroy anchor instead - so also clear the
    // overlay as soon as the server confirms the destroy is under way, or the
    // page would sit on the busy card until the workflow finished.
    if (busy && ["destroy", "delete"].includes(pendingAction) && s.my_session?.phase === "destroying") {
      busy = false; pendingAction = null;
    }

    // Auto-open is separate from clearing busy above, and fires exactly once
    // per session becoming active - tracked on the session object itself so
    // it survives busy already being false by the time healthz passes.
    //
    // A NEW TAB, not location.href: with the password baked into the URL
    // (see loginUrl()) the desktop no longer needs this page open to log in,
    // but navigating THIS tab away would still lose the Destroy button and
    // the fallback copy-the-password card if auto-open gets blocked. Falling
    // through to renderMine() below keeps this tab on the "Running" card,
    // whichever tab the user actually looks at.
    if (startedByMe && s.my_session?.status === "active") {
      startedByMe = false;
      // window.open() here runs from a TIMER, not a click, so it is not a user
      // gesture - and popup blockers refuse those, returning null, silently.
      // The desktop was ready and the page appeared to do nothing at all.
      // Capture the refusal so the card below can show a real call to action.
      let opened = null;
      const target = s.my_session.os === "windows"
        ? s.my_session.url
        : loginUrl(s.my_session.url, session?.user_id, s.my_session.password);
      try { opened = window.open(target, "_blank", "noopener"); } catch { /* blocked */ }
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
