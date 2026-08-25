const $ = (id) => document.getElementById(id);
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );

let session = null;
let googleRendered = false;

function fmtDur(sec) {
  const m = Math.floor(sec / 60), h = Math.floor(m / 60);
  return h ? `${h}h ${m % 60}m` : `${m}m`;
}

function renderSessions(sessions) {
  const rows = Object.entries(sessions || {});
  const host = $("sessions");
  host.innerHTML = rows.length ? "" : '<div class="sub">Nobody running right now.</div>';
  for (const [uname, sess] of rows) {
    const row = document.createElement("div");
    row.className = "sess-row";
    row.innerHTML = `<div><strong>${esc(uname)}</strong><div class="who">${esc(sess.email || "")} &middot; ${esc(sess.status)}</div></div>`;
    if (["active", "ready", "pending"].includes(sess.status)) {
      const b = document.createElement("button");
      b.className = "stop"; b.textContent = "Destroy";
      b.onclick = () => destroy(uname);
      row.appendChild(b);
    }
    host.appendChild(row);
  }
}

function renderTierList(el, emails, onRemove) {
  el.innerHTML = emails.length ? "" : '<div class="sub">None yet.</div>';
  for (const email of emails) {
    const row = document.createElement("div");
    row.className = "sess-row";
    row.innerHTML = `<div>${esc(email)}</div>`;
    const b = document.createElement("button");
    b.className = "stop"; b.textContent = "Remove";
    b.onclick = () => onRemove(email);
    row.appendChild(b);
    el.appendChild(row);
  }
}

async function destroy(username) {
  if (!confirm(`Destroy ${username}'s desktop?`)) return;
  const r = await fetch("/api/dispatch", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "destroy", username }),
  });
  if (!r.ok) $("err").textContent = (await r.json()).error || await r.text();
}

async function setUser(list, action, email) {
  const r = await fetch("/api/admin/users", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ list, action, email }),
  });
  if (!r.ok) { $("err").textContent = (await r.json()).error || await r.text(); return; }
  poll();
}

async function saveLimit() {
  const minutes = Number($("limit-input").value);
  const r = await fetch("/api/admin/config", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ guest_limit_minutes: minutes }),
  });
  if (!r.ok) $("err").textContent = (await r.json()).error || await r.text();
}

async function loadHistory() {
  try {
    const r = await fetch("/api/history", { cache: "no-store" });
    if (!r.ok) return;
    const { events } = await r.json();
    $("history").innerHTML = !events?.length
      ? '<div class="sub">Nothing recorded yet.</div>'
      : `<table><thead><tr><th>when</th><th>event</th><th>user</th><th>email</th></tr></thead><tbody>` +
        events.slice(0, 40).map((e) => `<tr>
          <td>${esc(new Date(e.ts * 1000).toLocaleString())}</td>
          <td>${esc(e.event)}</td><td>${esc(e.username || "")}</td>
          <td>${esc(e.email || "")}</td></tr>`).join("") +
        "</tbody></table>";
  } catch { /* history is informational */ }
}

function onGoogleCredential(resp) {
  $("err").textContent = "";
  $("g-wrap").innerHTML = '<div class="sub">Signing in&hellip;</div>';
  fetch("/api/google-login", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ credential: resp.credential }),
  })
    .then((r) => { if (!r.ok) throw new Error("sign-in rejected"); return r.json(); })
    .then(() => location.reload())
    .catch((e) => { $("err").textContent = e.message; poll(); });
}

async function poll() {
  try {
    const s = await (await fetch("/api/admin/state", { cache: "no-store" })).json();
    if (s.error) $("err").textContent = s.error;

    if (s.google_client_id && !googleRendered && window.google?.accounts?.id) {
      googleRendered = true;
      google.accounts.id.initialize({ client_id: s.google_client_id, callback: onGoogleCredential });
      google.accounts.id.renderButton($("g-wrap"), { theme: "filled_black", size: "large" });
    }

    session = s.session || null;
    $("g-wrap").style.display = session ? "none" : (s.google_client_id ? "flex" : "none");
    $("g-signed").style.display = session ? "flex" : "none";
    if (session) $("g-email").textContent = session.email;

    const isAdmin = Boolean(session?.is_admin);
    $("not-admin").style.display = session && !isAdmin ? "block" : "none";
    for (const id of ["sessions-card", "config-card", "tiers-card", "history-card"]) {
      $(id).style.display = isAdmin ? "block" : "none";
    }
    if (!isAdmin) return;

    renderSessions(s.sessions);
    renderTierList($("admin-list"), s.admins, (email) => setUser("admins", "remove", email));
    renderTierList($("permanent-list"), s.permanent_users, (email) => setUser("permanent_users", "remove", email));
    if (document.activeElement !== $("limit-input")) $("limit-input").value = s.guest_limit_minutes;
    loadHistory();
  } catch (e) {
    $("err").textContent = "status unreachable: " + e.message;
  }
}

$("g-signout").onclick = () => {
  try { google.accounts.id.disableAutoSelect(); } catch { /* not loaded yet */ }
  fetch("/api/google-logout", { method: "POST" }).then(() => location.reload());
};
$("limit-save").onclick = saveLimit;
$("admin-add").onclick = () => {
  const email = $("admin-email").value.trim();
  if (email) setUser("admins", "add", email);
};
$("permanent-add").onclick = () => {
  const email = $("permanent-email").value.trim();
  if (email) setUser("permanent_users", "add", email);
};

poll();
setInterval(poll, 5000);
