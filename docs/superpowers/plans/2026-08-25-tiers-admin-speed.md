# Access Tiers, Admin Console, and Boot/Destroy Speed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-admin env var with KV-backed admin/permanent-user tiers, ship a separate `admin.desktop.mnour.dev` console, enforce a hard time limit on guest sessions, and cut boot/destroy time by splitting Terraform's network resources out of the per-session stack and pre-baking the desktop's container image into an AMI.

**Architecture:** Three tiers (admin, permanent user, guest) are computed at request time from two Redis sets (`admins`, `permanent_users`) rather than stored per-session, so a tier change takes effect on the next poll. A new static page + API routes at `admin.desktop.mnour.dev` (same Vercel project, routed by Host header) give admins a session list, per-user destroy, tier management, and a guest time-limit control. Guest sessions get an `expires_at` written at session-ready time and are torn down by a rewritten, schedule-enabled reaper that compares EC2 `LaunchTime` against the admin-configured limit — no in-guest activity tracking. Terraform is split into a `network/` stack (VPC, subnet, IGW, route table, one shared security group, one shared key pair — created once, left standing, free while idle) and the existing per-session stack (now just the instance + DNS record). A custom AMI, built by an on-demand workflow, replaces the base Ubuntu AMI so the ~2GB desktop image never needs pulling at boot.

**Tech Stack:** Same as the existing project — Vercel serverless functions (Node 22, `@upstash/redis`), vanilla JS front end, Terraform 1.15.7 / AWS provider ~> 5.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-25-tiers-admin-speed-design.md`

## Global Constraints

- **AWS region for the desktop stack is `ap-south-1`, availability zone `ap-south-1c`.** Never change this without also updating `desktop-up.yml`/`desktop-down.yml`/`desktop-reaper.yml`'s `AWS_REGION`/`AWS_AZ` env — they are the single source of truth today and must stay in lock-step with `terraform/network`.
- **The Terraform state bucket is `ephemeral-desktop-643902831477-tfstate`, region `me-central-1`** (the bucket's own region — unrelated to where compute runs). Every new remote-state reference uses this exact bucket/region.
- **No NAT Gateway, no Elastic IP, anywhere.** The network stack must not introduce either.
- **The panel holds no AWS or Terraform credentials, ever.** All AWS actions stay inside GitHub Actions; the panel only calls the GitHub API (`GH_TOKEN`) and Redis.
- **Never widen who can call `/api/session-ready`, `/api/session-ended`, `/api/data-wiped`** beyond the existing `Bearer $HUB_CALLBACK_SECRET` check — no new secret is introduced for the reaper's config read; it reuses `HUB_CALLBACK_SECRET`.
- **A tier is computed from the signed-in email at request time, never cached on the session cookie itself** — the cookie only carries `sub`, `email`, `user_id`, `exp`; `is_admin`/`can_persist` are attached after a KV lookup on every request.
- **There must always be at least one admin.** Removing the last admin from the `admins` set is rejected server-side.
- **Commit at the end of every task. Never batch multiple tasks into one commit.**
- Author identity for commits: `Mohamed Nour <mnuowr@gmail.com>`.
- Local clone for this work: `/tmp/claude-1001/-home-n4/48189eb5-d0f2-4833-990e-79897de6e14f/scratchpad/ephemeral-cloud-desktop`, remote `mn0ur/ephemeral-cloud-desktop`, default branch `main`.
- After every panel (`panel/`) change, redeploy with `cd panel && vercel --prod` (linked project: `n4mu0r-8002s-projects/panel`) before manual verification — Vercel does not auto-deploy on push in this project's current setup.

---

### Task 1: KV-backed tiers in `lib/state.js`

**Files:**
- Modify: `panel/lib/state.js`

**Interfaces:**
- Consumes: nothing new — same `requireRedis()` helper already in the file.
- Produces (used by Tasks 2, 3, 6, 9, 10): `getAdmins()`, `isAdmin(email)`, `addAdmin(email)`, `removeAdmin(email)` (returns `{ ok: true }` or `{ ok: false, error }`), `getPermanentUsers()`, `isPermanentUser(email)`, `addPermanentUser(email)`, `removePermanentUser(email)`, `getGuestLimitMinutes()` (returns a `Number`), `setGuestLimitMinutes(n)`.

- [ ] **Step 1: Add the new Redis keys to the `K` map**

In `panel/lib/state.js`, extend the existing `K` object:

```js
const K = {
  sessions: "sessions",   // hash: username -> session JSON
  users: "users",         // hash: google sub -> username
  usernames: "usernames", // hash: username -> google sub  (reverse, for collisions)
  history: "history",     // list: newest first
  dataFlags: "dataflags", // hash: username -> "1" when they have a saved volume
  admins: "admins",             // set: emails with full admin access
  permanentUsers: "permanent_users", // set: emails allowed to persist data
  config: "config",             // hash: guest_limit_minutes, etc.
};
```

- [ ] **Step 2: Add the admins section, seeded on first read**

Append to `panel/lib/state.js`:

```js
// -- tiers --------------------------------------------------------------

// Seeded lazily rather than at deploy time: a fresh Redis attach must never
// leave the system with zero admins, and doing it here means it self-heals
// even if the set is ever emptied by mistake.
const DEFAULT_ADMIN_EMAIL = "mnuowr@gmail.com";
const DEFAULT_GUEST_LIMIT_MINUTES = 20;

export async function getAdmins() {
  const r = requireRedis();
  let members = await r.smembers(K.admins);
  if (!members.length) {
    await r.sadd(K.admins, DEFAULT_ADMIN_EMAIL);
    members = [DEFAULT_ADMIN_EMAIL];
  }
  return members;
}

export async function isAdmin(email) {
  if (!email) return false;
  return (await getAdmins()).includes(email.toLowerCase());
}

export async function addAdmin(email) {
  await requireRedis().sadd(K.admins, email.toLowerCase());
  await logEvent("admin_added", { email });
  return { ok: true };
}

export async function removeAdmin(email) {
  const admins = await getAdmins();
  const target = email.toLowerCase();
  if (admins.length <= 1 && admins.includes(target)) {
    return { ok: false, error: "cannot remove the last admin" };
  }
  await requireRedis().srem(K.admins, target);
  await logEvent("admin_removed", { email });
  return { ok: true };
}

// -- permanent users ------------------------------------------------------

export async function getPermanentUsers() {
  return (await requireRedis().smembers(K.permanentUsers)) || [];
}

export async function isPermanentUser(email) {
  if (!email) return false;
  return (await getPermanentUsers()).includes(email.toLowerCase());
}

export async function addPermanentUser(email) {
  await requireRedis().sadd(K.permanentUsers, email.toLowerCase());
  await logEvent("permanent_user_added", { email });
  return { ok: true };
}

export async function removePermanentUser(email) {
  await requireRedis().srem(K.permanentUsers, email.toLowerCase());
  await logEvent("permanent_user_removed", { email });
  return { ok: true };
}

// -- guest session limit ---------------------------------------------------

export async function getGuestLimitMinutes() {
  const v = await requireRedis().hget(K.config, "guest_limit_minutes");
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_GUEST_LIMIT_MINUTES;
}

export async function setGuestLimitMinutes(n) {
  const minutes = Math.max(1, Math.round(Number(n)));
  await requireRedis().hset(K.config, { guest_limit_minutes: String(minutes) });
  await logEvent("guest_limit_changed", { minutes });
  return minutes;
}
```

Note: `getAdmins`/`isAdmin`/etc. lowercase the email on write and compare
lowercased, since Google emails are case-insensitive but a human typing one
into the admin page might not match the casing Google reports.

- [ ] **Step 3: Verify with a one-off script (no test framework in this repo)**

This repo has no Jest/Vitest setup (`panel/package.json` has no `scripts` or
test dependency) — existing panel code has always been verified by deploying
and curling live endpoints, not unit tests. Follow that pattern. Verification
for this step happens as part of Task 9 once the admin API can exercise these
functions end-to-end; for now just confirm the file parses:

```bash
node --check panel/lib/state.js
```
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add panel/lib/state.js
git commit -m "feat: KV-backed admin/permanent-user tiers and guest time limit"
git push origin HEAD:main
```

---

### Task 2: Make session tier-aware in `lib/auth.js` and its three callers

**Files:**
- Modify: `panel/lib/auth.js`
- Modify: `panel/api/status.js:25`
- Modify: `panel/api/dispatch.js:18`
- Modify: `panel/api/history.js:5`

**Interfaces:**
- Consumes: `isAdmin`, `isPermanentUser` from Task 1.
- Produces (used by Tasks 3, 4, 5, 9, 10): `sessionFromRequest(req)` is now `async` and returns a payload with `is_admin` (bool) and `can_persist` (bool, `is_admin || permanent user`) attached, or `null`.

- [ ] **Step 1: Remove `ADMIN_GOOGLE_SUB` and make admin/persist async**

In `panel/lib/auth.js`, delete this line:

```js
export const ADMIN_GOOGLE_SUB = process.env.ADMIN_GOOGLE_SUB || "";
```

Replace `verifySession`'s last two lines:

```js
  if (!payload.exp || payload.exp < Date.now() / 1000) return null;
  payload.is_admin = Boolean(ADMIN_GOOGLE_SUB) && payload.sub === ADMIN_GOOGLE_SUB;
  return payload;
}
```

with a version that no longer computes tier (moved to `sessionFromRequest`,
since tier needs an async KV read and `verifySession` is used purely for
cookie verification):

```js
  if (!payload.exp || payload.exp < Date.now() / 1000) return null;
  return payload;
}
```

- [ ] **Step 2: Make `sessionFromRequest` async and tier-aware**

Add the import at the top of `panel/lib/auth.js`:

```js
import { isAdmin, isPermanentUser } from "./state.js";
```

Replace:

```js
export function sessionFromRequest(req) {
  const raw = req.headers.cookie || "";
  const match = raw.split(/;\s*/).find((c) => c.startsWith("session="));
  if (!match) return null;
  return verifySession(decodeURIComponent(match.slice("session=".length)));
}
```

with:

```js
export async function sessionFromRequest(req) {
  const raw = req.headers.cookie || "";
  const match = raw.split(/;\s*/).find((c) => c.startsWith("session="));
  if (!match) return null;
  const payload = verifySession(decodeURIComponent(match.slice("session=".length)));
  if (!payload) return null;
  const admin = await isAdmin(payload.email);
  payload.is_admin = admin;
  payload.can_persist = admin || (await isPermanentUser(payload.email));
  return payload;
}
```

- [ ] **Step 3: Update the three callers to `await`**

`panel/api/status.js:25` — change:
```js
  const session = sessionFromRequest(req);
```
to:
```js
  const session = await sessionFromRequest(req);
```

`panel/api/dispatch.js:18` — same change:
```js
  const session = await sessionFromRequest(req);
```

`panel/api/history.js` — the whole handler becomes:
```js
import { sessionFromRequest } from "../lib/auth.js";
import { readHistory } from "../lib/state.js";

export default async function handler(req, res) {
  const session = await sessionFromRequest(req);
  if (!session?.is_admin) return res.status(403).json({ error: "admin only" });
  return res.status(200).json({ events: await readHistory(500) });
}
```

- [ ] **Step 4: Verify**

```bash
node --check panel/lib/auth.js panel/api/status.js panel/api/dispatch.js panel/api/history.js
```
Expected: no output.

Grep to confirm no remaining synchronous call sites or `ADMIN_GOOGLE_SUB`
references:
```bash
grep -rn "ADMIN_GOOGLE_SUB\|= sessionFromRequest(req)" panel/
```
Expected: no matches (every call site now reads `await sessionFromRequest(req)`).

- [ ] **Step 5: Remove the now-dead `ADMIN_GOOGLE_SUB` from Vercel**

```bash
cd /tmp/claude-1001/-home-n4/48189eb5-d0f2-4833-990e-79897de6e14f/scratchpad/ephemeral-cloud-desktop/panel
vercel env rm ADMIN_GOOGLE_SUB production --yes
```
This is safe only after Task 9 (admin page) confirms the seeded
`mnuowr@gmail.com` admin works — note it here, but actually run this
removal at the end of Task 9's verification, not before.

- [ ] **Step 6: Commit**

```bash
git add panel/lib/auth.js panel/api/status.js panel/api/dispatch.js panel/api/history.js
git commit -m "feat: compute admin/persist tier from KV instead of ADMIN_GOOGLE_SUB"
git push origin HEAD:main
```

---

### Task 3: Enforce and record tier on desktop start (`api/dispatch.js`)

**Files:**
- Modify: `panel/api/dispatch.js`

**Interfaces:**
- Consumes: `session.can_persist` from Task 2.
- Produces (used by Task 4): every session record written at start time now
  includes `is_guest: boolean`, so `session-ready.js` doesn't need a second
  tier lookup.

- [ ] **Step 1: Trust the server's tier check, not the client's checkbox**

In `panel/api/dispatch.js`, inside the `if (action === "start")` block,
replace:

```js
    const persist = Boolean(req.body?.persist);
    await putSession(me, {
      status: "pending",
      email: session.email,
      dispatched_at: Date.now() / 1000,
    });
```

with:

```js
    // A guest cannot forge "persist: true" in the request body - the
    // client only shows the checkbox when can_persist is true, but the
    // server is the actual enforcement point.
    const persist = session.can_persist && Boolean(req.body?.persist);
    await putSession(me, {
      status: "pending",
      email: session.email,
      dispatched_at: Date.now() / 1000,
      is_guest: !session.can_persist,
    });
```

- [ ] **Step 2: Verify**

```bash
node --check panel/api/dispatch.js
```

- [ ] **Step 3: Commit**

```bash
git add panel/api/dispatch.js
git commit -m "feat: enforce persist tier server-side, tag pending sessions as guest"
git push origin HEAD:main
```

---

### Task 4: Guest expiry on session-ready (`api/session-ready.js`)

**Files:**
- Modify: `panel/api/session-ready.js`

**Interfaces:**
- Consumes: `getGuestLimitMinutes()` from Task 1; `prior.is_guest` written by Task 3.
- Produces (used by Task 5, 7): a guest's session record gains `expires_at`
  (unix seconds); a non-guest's does not.

- [ ] **Step 1: Compute and carry `expires_at`**

In `panel/api/session-ready.js`, add the import:

```js
import { getGuestLimitMinutes } from "../lib/state.js";
```

Replace the `putSession` call:

```js
  await putSession(username, {
    status: "ready", // the page polls /healthz before calling it active
    email,
    url: req.body?.url || null,
    password: req.body?.password || null,
    started_at: Date.now() / 1000,
  });
```

with:

```js
  const startedAt = Date.now() / 1000;
  const isGuest = Boolean(prior.is_guest);
  await putSession(username, {
    status: "ready", // the page polls /healthz before calling it active
    email,
    url: req.body?.url || null,
    password: req.body?.password || null,
    started_at: startedAt,
    is_guest: isGuest,
    ...(isGuest ? { expires_at: startedAt + (await getGuestLimitMinutes()) * 60 } : {}),
  });
```

- [ ] **Step 2: Verify**

```bash
node --check panel/api/session-ready.js
```

- [ ] **Step 3: Commit**

```bash
git add panel/api/session-ready.js
git commit -m "feat: stamp guest sessions with expires_at at session-ready time"
git push origin HEAD:main
```

---

### Task 5: Front-end — gate persist checkbox, show guest countdown, drop the admin card

**Files:**
- Modify: `panel/public/app.js`
- Modify: `panel/public/index.html`

**Interfaces:**
- Consumes: `session.can_persist`, `my_session.expires_at` (already flow
  through `/api/status` unchanged, since `status.js` returns the full
  `session` object and the full `my_session` record from Redis with no
  filtering needed here).

- [ ] **Step 1: Gate the persist checkbox on `can_persist`**

In `panel/public/app.js`, inside `renderMine`, replace:

```js
    box.innerHTML = `
      <label><input type="checkbox" id="persist"> Keep my files after destroy</label>
      <div class="row"><button id="start" class="go">Start my desktop</button></div>
      ${dataBlock}`;
```

with:

```js
    const persistLabel = session.can_persist
      ? `<label><input type="checkbox" id="persist"> Keep my files after destroy</label>`
      : "";
    box.innerHTML = `
      ${persistLabel}
      <div class="row"><button id="start" class="go">Start my desktop</button></div>
      ${dataBlock}`;
```

- [ ] **Step 2: Show a countdown for guests in the running/booting card**

Replace:

```js
  const running = mine.status === "active";
  let html = `<div><span class="dot ${running ? "up" : "work"}"></span> ${running ? "Running" : "Booting&hellip;"}`;
  if (running && mine.started_at) {
    const secs = Date.now() / 1000 - mine.started_at;
    html += ` <span class="sub">&middot; ${fmtDur(secs)} &middot; ~$${((secs / 3600) * (s.hourly_usd || 0.0529)).toFixed(2)} this session</span>`;
  }
  html += "</div>";
```

with:

```js
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
```

- [ ] **Step 3: Remove admin rendering from the public page**

Delete the entire `renderAdmin` function and its call site. Remove:
```js
    renderMine(s);
    renderAdmin(s);
```
replace with:
```js
    renderMine(s);
```
Then delete the whole `function renderAdmin(s) { ... }` block and the whole
`async function loadHistory() { ... }` block (both now unused on this page —
they move to `admin.js` in Task 10).

- [ ] **Step 4: Remove the now-unused markup from `index.html`**

In `panel/public/index.html`, delete these two blocks entirely:

```html
<div id="admin-card" class="card" style="display:none">
  <h2>All sessions</h2>
  <div id="admin-sessions"></div>
</div>

<div id="history-card" class="card" style="display:none">
  <h2>History</h2>
  <div id="history"></div>
</div>
```

- [ ] **Step 5: Verify**

```bash
node --check panel/public/app.js
grep -n "admin-card\|history-card\|renderAdmin\|loadHistory" panel/public/app.js panel/public/index.html
```
Expected: the grep finds nothing (all four names fully removed).

- [ ] **Step 6: Deploy and manually verify**

```bash
cd panel && vercel --prod
```
Then sign in at `desktop.mnour.dev` as the seeded admin
(`mnuowr@gmail.com`) — confirm the persist checkbox still appears (admins
can persist), no admin card/history table remain on this page, and the
page otherwise looks identical to before.

- [ ] **Step 7: Commit**

```bash
git add panel/public/app.js panel/public/index.html
git commit -m "feat: gate persist checkbox on tier, show guest countdown, drop admin UI from main page"
git push origin HEAD:main
```

---

### Task 6: Reaper config endpoint (`api/admin/config.js`)

**Files:**
- Create: `panel/api/admin/config.js`

**Interfaces:**
- Consumes: `getGuestLimitMinutes`, `setGuestLimitMinutes` from Task 1;
  `sessionFromRequest`, `bearerOk`, `HUB_CALLBACK_SECRET` from `lib/auth.js`.
- Produces (used by Task 7's reaper, and Task 10's admin page):
  `GET /api/admin/config` → `{ guest_limit_minutes }`, callable either by an
  admin's session cookie or by `Bearer $HUB_CALLBACK_SECRET` (the reaper has
  no Google session). `POST /api/admin/config` with body
  `{ guest_limit_minutes }` → requires an admin session; returns the same
  shape.

- [ ] **Step 1: Write the endpoint**

```js
import { sessionFromRequest, bearerOk, HUB_CALLBACK_SECRET } from "../../lib/auth.js";
import { getGuestLimitMinutes, setGuestLimitMinutes } from "../../lib/state.js";

export default async function handler(req, res) {
  if (req.method === "GET") {
    // Either an admin browsing the console, or the reaper workflow reading
    // the current limit before deciding what to destroy - the reaper has no
    // Google session, so it authenticates the same way the START/DESTROY
    // callbacks already do.
    const session = await sessionFromRequest(req);
    const viaCallback = bearerOk(req, HUB_CALLBACK_SECRET);
    if (!session?.is_admin && !viaCallback) {
      return res.status(403).json({ error: "admin only" });
    }
    return res.status(200).json({ guest_limit_minutes: await getGuestLimitMinutes() });
  }

  if (req.method === "POST") {
    const session = await sessionFromRequest(req);
    if (!session?.is_admin) return res.status(403).json({ error: "admin only" });
    const minutes = Number(req.body?.guest_limit_minutes);
    if (!Number.isFinite(minutes) || minutes <= 0) {
      return res.status(400).json({ error: "guest_limit_minutes must be a positive number" });
    }
    return res.status(200).json({ guest_limit_minutes: await setGuestLimitMinutes(minutes) });
  }

  return res.status(405).json({ error: "GET or POST only" });
}
```

- [ ] **Step 2: Verify**

```bash
node --check panel/api/admin/config.js
```

- [ ] **Step 3: Deploy and manually verify with curl**

```bash
cd panel && vercel --prod
curl -s https://desktop.mnour.dev/api/admin/config
```
Expected: `{"error":"admin only"}` (no session, no bearer token). Then, using
the `HUB_CALLBACK_SECRET` value (from `vercel env pull` into a local
`.env.local`, not printed to chat):
```bash
source .env.local
curl -s -H "Authorization: Bearer $HUB_CALLBACK_SECRET" https://desktop.mnour.dev/api/admin/config
```
Expected: `{"guest_limit_minutes":20}` (the seeded default).

- [ ] **Step 4: Commit**

```bash
git add panel/api/admin/config.js
git commit -m "feat: add /api/admin/config for reading and setting the guest time limit"
git push origin HEAD:main
```

---

### Task 7: Rewrite the reaper — LaunchTime-based, scheduled

**Files:**
- Modify: `.github/workflows/desktop-reaper.yml`

**Interfaces:**
- Consumes: `GET /api/admin/config` from Task 6.
- Produces: guest desktops older than the configured limit are destroyed
  automatically, on a 5-minute schedule, without depending on anything
  running inside the instance.

- [ ] **Step 1: Replace the trigger and the discovery/destroy logic**

Replace the whole file with:

```yaml
name: Desktop - REAPER

# Per-user desktops carry a hard time limit set on the admin console
# (admin.desktop.mnour.dev) and enforced here by comparing each guest
# instance's LaunchTime (from the EC2 API) against that limit - not an
# in-guest activity tracker, which was never verified against real traffic
# and whose failure mode (silently going stale) is worse than this one's
# (a few minutes of scheduling drift, accepted).
#
# There is no fixed list of usernames to loop over - discovery is by AWS
# tag (Role=guest-desktop), not a hardcoded set. The owner's own desktop
# and any permanent user's desktop carry no such tag and are never
# touched by this workflow.
on:
  workflow_dispatch: {}
  schedule:
    - cron: "*/5 * * * *"

permissions:
  contents: read

jobs:
  reap:
    name: destroy anything past its time limit
    runs-on: ubuntu-latest

    env:
      AWS_REGION: ap-south-1
      AWS_AZ: ap-south-1c
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.15.7

      - name: Configure AWS
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          if [ -z "$AWS_ACCESS_KEY_ID" ]; then
            echo "::error::AWS secrets are not set."
            exit 1
          fi
          echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> "$GITHUB_ENV"
          echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> "$GITHUB_ENV"
          echo "AWS_DEFAULT_REGION=$AWS_REGION" >> "$GITHUB_ENV"

      - name: Discover every live guest desktop, destroy anything past the limit
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          HUB_CALLBACK_SECRET: ${{ secrets.HUB_CALLBACK_SECRET }}
        run: |
          set -uo pipefail
          NOW=$(date -u +%s)

          LIMIT_MIN=$(curl -fsS -H "Authorization: Bearer $HUB_CALLBACK_SECRET" \
            https://desktop.mnour.dev/api/admin/config | jq -r '.guest_limit_minutes')
          if ! [[ "$LIMIT_MIN" =~ ^[0-9]+$ ]]; then
            echo "::error::could not read guest_limit_minutes from the panel ('$LIMIT_MIN') - not destroying anything this run"
            exit 1
          fi
          LIMIT_S=$((LIMIT_MIN * 60))
          echo "current guest limit: ${LIMIT_MIN}m (${LIMIT_S}s)"

          # LaunchTime and username together, tab-separated - LaunchTime alone
          # cannot be joined back to a username without a second API call per
          # instance.
          ROWS=$(aws ec2 describe-instances --region "$AWS_REGION" \
            --filters "Name=tag:Role,Values=guest-desktop" "Name=instance-state-name,Values=running,pending" \
            --query 'Reservations[].Instances[].[Tags[?Key==`Owner`]|[0].Value,LaunchTime]' \
            --output text)

          if [ -z "$ROWS" ]; then
            echo "no guest desktops currently running"
            exit 0
          fi

          echo "$ROWS" | while IFS=$'\t' read -r USERNAME LAUNCH_TIME; do
            [ -z "$USERNAME" ] && continue
            LAUNCH_S=$(date -u -d "$LAUNCH_TIME" +%s)
            AGE_S=$((NOW - LAUNCH_S))

            if [ "$AGE_S" -ge "$LIMIT_S" ]; then
              echo "$USERNAME: age ${AGE_S}s >= ${LIMIT_S}s limit - destroying"
              terraform -chdir=terraform init -input=false -reconfigure \
                -backend-config="key=desktop/user-$USERNAME/terraform.tfstate"
              TF_VAR_username="$USERNAME" terraform -chdir=terraform destroy -auto-approve -input=false

              curl -fsS -X POST "https://desktop.mnour.dev/api/session-ended" \
                -H "Authorization: Bearer $HUB_CALLBACK_SECRET" \
                -H "Content-Type: application/json" \
                -d "{\"username\":\"$USERNAME\",\"reason\":\"time_limit\"}" \
                || echo "::warning::callback failed for $USERNAME - destroy already succeeded"
            else
              echo "$USERNAME: age ${AGE_S}s, under the ${LIMIT_S}s limit - leaving it"
            fi
          done
```

- [ ] **Step 2: Verify the YAML parses**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/desktop-reaper.yml'))" && echo OK
```
Expected: `OK`.

- [ ] **Step 3: End-to-end verify with a short limit**

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -H "Cookie: session=$ADMIN_SESSION_COOKIE" \
  -d '{"guest_limit_minutes": 2}' https://desktop.mnour.dev/api/admin/config
```
(Get `$ADMIN_SESSION_COOKIE` from the browser's dev tools after signing in
as the admin — this is a manual, one-time verification step, not something
to script into CI.) Then start a guest desktop from a second Google account
(or manually tag a test instance), wait ~3 minutes, and dispatch the reaper
by hand:
```bash
gh workflow run "Desktop - REAPER" -R mn0ur/ephemeral-cloud-desktop
```
Confirm via `gh run view` that it destroyed the test instance, then reset
the limit back to 20:
```bash
curl -s -X POST -H "Content-Type: application/json" \
  -H "Cookie: session=$ADMIN_SESSION_COOKIE" \
  -d '{"guest_limit_minutes": 20}' https://desktop.mnour.dev/api/admin/config
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/desktop-reaper.yml
git commit -m "feat: rewrite reaper to use LaunchTime + admin-configured limit, enable schedule"
git push origin HEAD:main
```

---

### Task 8: Tier-management endpoint (`api/admin/users.js`) and full-state endpoint (`api/admin/state.js`)

**Files:**
- Create: `panel/api/admin/users.js`
- Create: `panel/api/admin/state.js`

**Interfaces:**
- Consumes: everything from Task 1, `sessionFromRequest` from Task 2,
  `loadSessions` (existing, from `lib/state.js`), `GOOGLE_CLIENT_ID` (existing,
  from `lib/auth.js`).
- Produces (used by Task 10's `admin.js`):
  `POST /api/admin/users` body `{ list: "admins" | "permanent_users", action:
  "add" | "remove", email }` → `{ ok, error? }`.
  `GET /api/admin/state` → `{ google_client_id, session, sessions, admins,
  permanent_users, guest_limit_minutes }` when signed in as an admin; `{
  google_client_id, session: null }` when not signed in; `403` when signed in
  but not an admin.

- [ ] **Step 1: Write `panel/api/admin/users.js`**

```js
import { sessionFromRequest } from "../../lib/auth.js";
import {
  addAdmin, removeAdmin, addPermanentUser, removePermanentUser,
} from "../../lib/state.js";

const ACTIONS = {
  admins: { add: addAdmin, remove: removeAdmin },
  permanent_users: { add: addPermanentUser, remove: removePermanentUser },
};

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const session = await sessionFromRequest(req);
  if (!session?.is_admin) return res.status(403).json({ error: "admin only" });

  const { list, action, email } = req.body || {};
  const fn = ACTIONS[list]?.[action];
  if (!fn) return res.status(400).json({ error: "unknown list or action" });
  if (!email || !email.includes("@")) return res.status(400).json({ error: "bad email" });

  const result = await fn(email);
  if (result?.ok === false) return res.status(400).json(result);
  return res.status(200).json({ ok: true });
}
```

- [ ] **Step 2: Write `panel/api/admin/state.js`**

```js
import { sessionFromRequest, GOOGLE_CLIENT_ID } from "../../lib/auth.js";
import {
  loadSessions, getAdmins, getPermanentUsers, getGuestLimitMinutes,
} from "../../lib/state.js";

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const session = await sessionFromRequest(req);

  if (!session) {
    return res.status(200).json({ google_client_id: GOOGLE_CLIENT_ID, session: null });
  }
  if (!session.is_admin) {
    return res.status(403).json({ error: "admin only" });
  }

  return res.status(200).json({
    google_client_id: GOOGLE_CLIENT_ID,
    session,
    sessions: await loadSessions(),
    admins: await getAdmins(),
    permanent_users: await getPermanentUsers(),
    guest_limit_minutes: await getGuestLimitMinutes(),
  });
}
```

- [ ] **Step 3: Verify**

```bash
node --check panel/api/admin/users.js panel/api/admin/state.js
```

- [ ] **Step 4: Deploy and manually verify**

```bash
cd panel && vercel --prod
curl -s https://desktop.mnour.dev/api/admin/state
```
Expected: `{"google_client_id":"...","session":null}` (no cookie sent).

- [ ] **Step 5: Commit**

```bash
git add panel/api/admin/users.js panel/api/admin/state.js
git commit -m "feat: add /api/admin/users and /api/admin/state"
git push origin HEAD:main
```

---

### Task 9: `admin.desktop.mnour.dev` — routing, page, and script

**Files:**
- Modify: `panel/vercel.json` (add rewrites)
- Create: `panel/public/admin.html`
- Create: `panel/public/admin.js`

**Interfaces:**
- Consumes: `/api/admin/state`, `/api/admin/users`, `/api/admin/config`
  (Task 8, 6), `/api/dispatch` with `action: "destroy"` (existing — already
  admin-aware via `session.is_admin`, see `panel/api/dispatch.js:79`, no
  changes needed there), `/api/google-login`, `/api/google-logout`
  (existing, unchanged — host-only cookies mean this domain gets its own
  independent sign-in from `desktop.mnour.dev`).
- Produces: a working admin console reachable once the domain is attached
  (Task 10 does the Vercel/DNS side).

- [ ] **Step 1: Add host-based rewrites to `panel/vercel.json`**

Replace the file:

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "functions": {
    "api/**/*.js": {
      "maxDuration": 10
    }
  },
  "rewrites": [
    {
      "source": "/",
      "has": [{ "type": "host", "value": "admin.desktop.mnour.dev" }],
      "destination": "/admin.html"
    },
    {
      "source": "/app.js",
      "has": [{ "type": "host", "value": "admin.desktop.mnour.dev" }],
      "destination": "/admin.js"
    }
  ]
}
```

This lets `admin.html` reference `/app.js` exactly like `index.html` does —
the rewrite decides which actual file is served, based on which domain the
request came in on.

- [ ] **Step 2: Write `panel/public/admin.html`**

Copy `panel/public/index.html` in full, then make exactly these two changes:
change `<title>cloud desktop</title>` to `<title>admin console</title>`, and
replace everything between `<body>` and `</body>` with:

```html
<div class="card">
  <div class="bar-top"><i></i><i></i><i></i></div>
  <h1>admin console</h1>
  <div class="sub">Sign in with an admin Google account.</div>

  <div id="g-wrap" class="g-wrap"></div>
  <div id="g-signed" class="signed-in" style="display:none">
    <span id="g-email"></span><button id="g-signout">Sign out</button>
  </div>
  <div id="g-disabled" class="sub" style="display:none;text-align:center;padding:1rem 0">
    Sign-in is not configured on this deployment.</div>
  <div id="not-admin" class="sub" style="display:none;text-align:center;padding:1rem 0">
    Signed in, but this account is not an admin.</div>
  <div id="err" class="err"></div>
</div>

<div id="sessions-card" class="card" style="display:none">
  <h2>All sessions</h2>
  <div id="sessions"></div>
</div>

<div id="config-card" class="card" style="display:none">
  <h2>Guest time limit</h2>
  <div class="row">
    <input id="limit-input" type="number" min="1" style="width:6rem">
    <button id="limit-save" class="go">Save</button>
  </div>
  <div class="sub" style="margin-top:.4rem">Minutes before a guest session is auto-destroyed.</div>
</div>

<div id="tiers-card" class="card" style="display:none">
  <h2>Admins</h2>
  <div id="admin-list"></div>
  <div class="row">
    <input id="admin-email" type="email" placeholder="email@example.com" style="flex:1">
    <button id="admin-add" class="go">Add</button>
  </div>

  <h2 style="margin-top:1.2rem">Permanent users</h2>
  <div id="permanent-list"></div>
  <div class="row">
    <input id="permanent-email" type="email" placeholder="email@example.com" style="flex:1">
    <button id="permanent-add" class="go">Add</button>
  </div>
</div>

<div id="history-card" class="card" style="display:none">
  <h2>History</h2>
  <div id="history"></div>
</div>

<script src="https://accounts.google.com/gsi/client" async defer></script>
<script src="/app.js"></script>
```

- [ ] **Step 3: Write `panel/public/admin.js`**

```js
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
```

- [ ] **Step 4: Verify**

```bash
node --check panel/public/admin.js
python3 -c "import json; json.load(open('panel/vercel.json'))" && echo OK
```

- [ ] **Step 5: Commit**

```bash
git add panel/vercel.json panel/public/admin.html panel/public/admin.js
git commit -m "feat: add admin console page, script, and host-based routing"
git push origin HEAD:main
```

---

### Task 10: Attach the `admin.desktop.mnour.dev` domain and verify end-to-end

**Files:** none (infra/ops task — no repo files change).

**Interfaces:**
- Consumes: Task 9's rewrites.
- Produces: `admin.desktop.mnour.dev` resolves to the same Vercel project and
  serves `admin.html`/`admin.js`.

- [ ] **Step 1: Deploy the latest panel code**

```bash
cd /tmp/claude-1001/-home-n4/48189eb5-d0f2-4833-990e-79897de6e14f/scratchpad/ephemeral-cloud-desktop/panel
vercel --prod
```

- [ ] **Step 2: Add the domain to the Vercel project**

```bash
vercel domains add admin.desktop.mnour.dev
```
This prints the DNS record Vercel expects (a `CNAME` to `cname.vercel-dns.com`,
matching the same pattern `desktop.mnour.dev` already uses — check with
`vercel domains inspect desktop.mnour.dev` if unsure of the exact target).

- [ ] **Step 3: Add the DNS record in Cloudflare**

This is a manual step in the Cloudflare dashboard (or via
`CLOUDFLARE_API_TOKEN` if scripting it) for the `mnour.dev` zone: a `CNAME`
record, name `admin.desktop`, pointing at the target Vercel printed in Step
2, proxy status set to **DNS only** (matching how `desktop.mnour.dev` itself
is configured — a proxied CNAME would put Vercel's TLS behind Cloudflare's,
which this project has deliberately avoided everywhere else per the
project's own "no NAT/no proxy surprises" philosophy).

- [ ] **Step 4: Verify the domain resolves and serves the right page**

```bash
curl -s https://admin.desktop.mnour.dev/ | grep -o "<title>[^<]*</title>"
```
Expected: `<title>admin console</title>` (not `cloud desktop`).

```bash
curl -s https://admin.desktop.mnour.dev/app.js | head -c 60
```
Expected: the start of `admin.js`'s content (`const $ = (id) =>`), not
`app.js`'s.

- [ ] **Step 5: Verify the full admin flow by hand**

Sign in at `admin.desktop.mnour.dev` as `mnuowr@gmail.com` — confirm the
sessions list, guest limit input (should show `20`), and admin/permanent
user lists all render. Add a second email as a permanent user, then sign in
to `desktop.mnour.dev` as that account (or check via `/api/status` with that
account's session cookie) and confirm the persist checkbox now appears for
them.

- [ ] **Step 6: Now safe to remove `ADMIN_GOOGLE_SUB` (deferred from Task 2)**

```bash
cd panel
vercel env rm ADMIN_GOOGLE_SUB production --yes
vercel --prod
```
Re-verify `mnuowr@gmail.com` is still recognized as admin after this
redeploy (it now comes purely from the seeded KV set, not the env var).

- [ ] **Step 7: No commit** (infra-only task, no file changes) — but note
completion:

```bash
echo "admin.desktop.mnour.dev live and verified $(date -u)" 
```

---

### Task 11: Split Terraform — persistent network stack

**Files:**
- Create: `terraform/network/main.tf`
- Create: `terraform/network/variables.tf`
- Create: `terraform/network/outputs.tf`
- Create: `terraform/network/backend.tf`
- Create: `terraform/network/versions.tf`

**Interfaces:**
- Consumes: nothing (applied standalone, once).
- Produces (used by Task 12): outputs `vpc_id`, `subnet_id`,
  `security_group_id`, `key_name`, `key_pair_id`, all read via
  `terraform_remote_state` from the existing `terraform/` stack.

- [ ] **Step 1: Write `terraform/network/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}
```

- [ ] **Step 2: Write `terraform/network/backend.tf`**

```hcl
terraform {
  backend "s3" {
    bucket       = "ephemeral-desktop-643902831477-tfstate"
    key          = "network/terraform.tfstate"
    region       = "me-central-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

- [ ] **Step 3: Write `terraform/network/variables.tf`**

```hcl
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "az_suffix" {
  type    = string
  default = "c" # ap-south-1c: cheapest spot zone for this instance family, measured 2026-08-10.
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "enable_ssh" {
  description = "Whether to create the shared debugging key pair and its ingress rule."
  type        = bool
  default     = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "../keys/desktop.pub"
}
```

- [ ] **Step 4: Write `terraform/network/main.tf`**

This is the exact set of resources being moved out of `terraform/main.tf`
(VPC, subnet, IGW, route table, route table association, the security group
and its rules, and the key pair), made username-independent since one
network now serves every session, any tier, any concurrency level:

```hcl
locals {
  az = "${var.region}${var.az_suffix}"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "desktop" {
  name        = "ephemeral-desktop-shared"
  description = "Shared by every desktop session, any tier, any concurrency slot."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.desktop.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 80
  to_port             = 80
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.desktop.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 443
  to_port             = 443
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.desktop.id
  description       = "Debugging access while SSM is unavailable. Key-only auth."
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 22
  to_port             = 22
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.desktop.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1"
}

resource "aws_key_pair" "desktop" {
  count = var.enable_ssh ? 1 : 0

  key_name   = "ephemeral-desktop-shared-key"
  public_key = trimspace(file("${path.module}/${var.ssh_public_key_path}"))
}
```

- [ ] **Step 5: Write `terraform/network/outputs.tf`**

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_id" {
  value = aws_subnet.public.id
}

output "security_group_id" {
  value = aws_security_group.desktop.id
}

output "key_name" {
  value = var.enable_ssh ? aws_key_pair.desktop[0].key_name : null
}
```

- [ ] **Step 6: Validate and apply once**

```bash
cd terraform/network
terraform init
terraform validate
terraform plan -out=tfplan
```
Read the plan output carefully — expect exactly the 11 resources listed
above, all creates, nothing else. Then:
```bash
terraform apply tfplan
terraform output
```
Record the outputs (`vpc_id`, `subnet_id`, `security_group_id`, `key_name`)
— Task 12 wires these in via `terraform_remote_state`, not by copy-pasting
these values.

- [ ] **Step 7: Commit**

```bash
cd /tmp/claude-1001/-home-n4/48189eb5-d0f2-4833-990e-79897de6e14f/scratchpad/ephemeral-cloud-desktop
git add terraform/network/
git commit -m "feat: create persistent network stack (VPC/subnet/SG/key pair), applied once"
git push origin HEAD:main
```

---

### Task 12: Point the per-session stack at the network stack, remove the duplicated resources

**Files:**
- Modify: `terraform/main.tf`

**Interfaces:**
- Consumes: Task 11's `terraform_remote_state` outputs.
- Produces: `terraform apply`/`destroy` in `terraform/` now only touch the
  instance, its guest volume attachment, and its DNS record.

- [ ] **Step 1: Add the remote-state data source**

In `terraform/main.tf`, alongside the existing `data.terraform_remote_state.persistent` block, add:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "ephemeral-desktop-643902831477-tfstate"
    key    = "network/terraform.tfstate"
    region = "me-central-1"
  }
}
```

- [ ] **Step 2: Delete the resources that moved**

Delete these resource blocks from `terraform/main.tf` entirely (they now
live in `terraform/network/main.tf`): `aws_vpc.main`,
`aws_internet_gateway.main`, `aws_subnet.public`, `aws_route_table.public`,
`aws_route_table_association.public`, `aws_security_group.desktop`, the four
`aws_vpc_security_group_ingress_rule`/`aws_vpc_security_group_egress_rule`
resources (`http`, `https`, `ssh`, `all`), and `aws_key_pair.desktop`.

- [ ] **Step 3: Repoint every reference to the deleted resources**

Search for every place `terraform/main.tf` referenced the deleted resources
by name, and replace with the remote-state output:

```bash
grep -n "aws_subnet.public\|aws_security_group.desktop\|aws_key_pair.desktop\[0\]" terraform/main.tf
```

Each match becomes a remote-state reference. Concretely, in
`aws_instance.desktop`:

```hcl
resource "aws_instance" "desktop" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.network.outputs.subnet_id
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.security_group_id]
  iam_instance_profile   = var.enable_instance_role ? aws_iam_instance_profile.desktop[0].name : null
  key_name               = var.enable_ssh ? data.terraform_remote_state.network.outputs.key_name : null
  ...
```

(keep every other argument on `aws_instance.desktop` exactly as it is today
— only `subnet_id`, `vpc_security_group_ids`, and `key_name` change).

- [ ] **Step 4: Validate against the real (already-populated) state**

```bash
cd terraform
terraform init -reconfigure -backend-config="key=desktop/terraform.tfstate"
terraform validate
terraform plan
```
Expected: the plan proposes destroying the *old* VPC/subnet/SG/key pair
resources that still exist under this state's ownership (since they were
just deleted from this file, Terraform sees them as "to remove from state,
resource still exists in AWS"). This is the one moment where care matters —
run:
```bash
terraform state list | grep -E "aws_vpc|aws_subnet|aws_internet_gateway|aws_route_table|aws_security_group|aws_key_pair"
```
and `terraform state rm` each one **instead of** letting `apply` destroy
them, since the equivalent resources already exist (freshly created) in the
network stack:
```bash
terraform state rm aws_vpc.main aws_internet_gateway.main aws_subnet.public \
  aws_route_table.public aws_route_table_association.public \
  aws_security_group.desktop aws_vpc_security_group_ingress_rule.http \
  aws_vpc_security_group_ingress_rule.https 'aws_vpc_security_group_ingress_rule.ssh[0]' \
  aws_vpc_security_group_egress_rule.all 'aws_key_pair.desktop[0]'
```
Then re-plan:
```bash
terraform plan
```
Expected: no changes (the instance's `subnet_id`/`vpc_security_group_ids`/
`key_name` already match the network stack's outputs, since it's the same
AZ and the same public key file).

- [ ] **Step 5: Repeat state surgery for the owner's own desktop state, if separately deployed**

The owner's own desktop (`desktop/terraform.tfstate`, no `guest_username`) is
the one just handled in Step 4. If any guest state keys
(`desktop/user-*/terraform.tfstate`) currently hold live resources, repeat
Steps 4-5's `terraform state rm` for each — check first:
```bash
aws s3 ls s3://ephemeral-desktop-643902831477-tfstate/desktop/ --recursive | grep user-
```
Expected at this point in the project: none (all test guest sessions were
destroyed in earlier work) — if the listing is empty, skip this step.

- [ ] **Step 6: Time a real start/destroy cycle, compare to baseline**

```bash
gh workflow run "Desktop - START" -R mn0ur/ephemeral-cloud-desktop
```
Watch the run duration in the Actions UI. Baseline from before this change:
~90s of the ~110s `terraform apply` step was network resource creation.
Expected now: the `terraform apply` step should drop to roughly the time
the instance itself takes to create (~15-20s) plus the DNS update (~1s).
Then:
```bash
gh workflow run "Desktop - DESTROY" -R mn0ur/ephemeral-cloud-desktop -f confirm=DESTROY
```
Same comparison for destroy.

- [ ] **Step 7: Commit**

```bash
git add terraform/main.tf
git commit -m "feat: point instance stack at the shared network stack, drop duplicated resources"
git push origin HEAD:main
```

---

### Task 13: Bake a custom AMI with the desktop image pre-loaded

**Files:**
- Create: `.github/workflows/bake-ami.yml`
- Modify: `terraform/main.tf` (swap the AMI data source)

**Interfaces:**
- Consumes: nothing new.
- Produces: `data.aws_ami.desktop` in `terraform/main.tf`, replacing
  `data.aws_ami.ubuntu`, resolving to the most recent AMI tagged
  `Project=ephemeral-desktop`.

- [ ] **Step 1: Write `.github/workflows/bake-ami.yml`**

```yaml
name: Bake Desktop AMI

# Manual only - this is not something that should run on every push. Run it
# when the desktop image (linuxserver/webtop) or base OS packages change and
# a fresh boot needs to pick that up.
on:
  workflow_dispatch: {}

permissions:
  contents: read

env:
  AWS_REGION: ap-south-1
  IMAGE: lscr.io/linuxserver/webtop:ubuntu-kde

jobs:
  bake:
    name: launch, pull image, snapshot, terminate
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> "$GITHUB_ENV"
          echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> "$GITHUB_ENV"
          echo "AWS_DEFAULT_REGION=$AWS_REGION" >> "$GITHUB_ENV"

      - name: Launch a throwaway instance in the default VPC
        run: |
          set -euo pipefail
          BASE_AMI=$(aws ec2 describe-images --owners 099720109477 \
            --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
                       "Name=virtualization-type,Values=hvm" \
            --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
          echo "base AMI: $BASE_AMI"

          SUBNET=$(aws ec2 describe-subnets \
            --filters "Name=default-for-az,Values=true" \
            --query 'Subnets[0].SubnetId' --output text)

          cat > bake-user-data.sh <<'EOF'
          #!/bin/bash
          set -euo pipefail
          apt-get update -y
          apt-get install -y --no-install-recommends docker.io
          systemctl enable --now docker
          docker pull "$IMAGE_PLACEHOLDER"
          touch /home/ubuntu/bake-complete
          EOF
          sed -i "s|\$IMAGE_PLACEHOLDER|$IMAGE|" bake-user-data.sh

          INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$BASE_AMI" --instance-type t3.medium \
            --subnet-id "$SUBNET" --associate-public-ip-address \
            --user-data file://bake-user-data.sh \
            --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ami-bake-temp}]' \
            --query 'Instances[0].InstanceId' --output text)
          echo "INSTANCE_ID=$INSTANCE_ID" >> "$GITHUB_ENV"
          aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

      - name: Wait for the image pull to finish
        run: |
          # No SSM/instance-role on this throwaway box - poll console output
          # for the completion marker instead of anything requiring inbound
          # access. Docker pulling ~2GB comfortably finishes well inside 10
          # minutes; if it doesn't, something is actually wrong and should
          # fail loud rather than snapshot a half-pulled image.
          for i in $(seq 1 30); do
            OUT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" --output text --query Output || true)
            if echo "$OUT" | grep -q "bake-complete\|cloud-init.*finished"; then
              sleep 30 # give dockerd a moment to flush the pulled layers to disk
              break
            fi
            sleep 20
          done

      - name: Snapshot into an AMI
        run: |
          set -euo pipefail
          STAMP=$(date -u +%Y%m%d%H%M%S)
          AMI_ID=$(aws ec2 create-image \
            --instance-id "$INSTANCE_ID" \
            --name "ephemeral-desktop-baked-$STAMP" \
            --tag-specifications "ResourceType=image,Tags=[{Key=Project,Value=ephemeral-desktop},{Key=BakedAt,Value=$STAMP}]" \
            --query ImageId --output text)
          echo "baked AMI: $AMI_ID - waiting for it to become available"
          aws ec2 wait image-available --image-ids "$AMI_ID"
          echo "## AMI baked" >> "$GITHUB_STEP_SUMMARY"
          echo "$AMI_ID, tagged Project=ephemeral-desktop" >> "$GITHUB_STEP_SUMMARY"

      - name: Terminate the throwaway instance
        if: always()
        run: aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" || true
```

- [ ] **Step 2: Verify the YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/bake-ami.yml'))" && echo OK
```

- [ ] **Step 3: Run it once and confirm an AMI appears**

```bash
gh workflow run "Bake Desktop AMI" -R mn0ur/ephemeral-cloud-desktop
```
Wait for completion (`gh run list --workflow="Bake Desktop AMI"`), then:
```bash
aws ec2 describe-images --owners self \
  --filters "Name=tag:Project,Values=ephemeral-desktop" \
  --query 'Images[].[ImageId,Name,CreationDate]' --output table
```
Expected: one row, a recent `CreationDate`.

- [ ] **Step 4: Swap the AMI data source in `terraform/main.tf`**

Replace:

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

with:

```hcl
data "aws_ami" "desktop" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Project"
    values = ["ephemeral-desktop"]
  }
}
```

Then update the one reference to it, in `aws_instance.desktop`:

```hcl
  ami                    = data.aws_ami.desktop.id
```

- [ ] **Step 5: Verify, then time a real boot against the ~4 minute baseline**

```bash
cd terraform
terraform validate
terraform plan
```
Expected: only `aws_instance.desktop` shows a change (new AMI ID forces
replacement — expected, this is the one-time cutover).

```bash
gh workflow run "Desktop - START" -R mn0ur/ephemeral-cloud-desktop
```
Once the run finishes, poll for the desktop coming up:
```bash
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://mnuowr.desktop.mnour.dev/healthz)
  echo "check $i: $code"
  [ "$code" = "200" ] && break
  sleep 10
done
```
Expected: `200` within roughly 1-2 minutes of the workflow completing (down
from the ~4 minutes measured before this change), since the image no longer
needs pulling. Then destroy it:
```bash
gh workflow run "Desktop - DESTROY" -R mn0ur/ephemeral-cloud-desktop -f confirm=DESTROY
```

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/bake-ami.yml terraform/main.tf
git commit -m "feat: bake desktop image into a custom AMI, eliminating the boot-time image pull"
git push origin HEAD:main
```

---

## Post-implementation check against the spec

- Three tiers, KV-backed, no more `ADMIN_GOOGLE_SUB` → Tasks 1, 2, 10 (Step 6).
- Admin console at a separate domain, same look-and-feel system → Tasks 9, 10.
- Admin can see all sessions, destroy any, manage admins/permanent users, set
  the guest limit → Task 8's endpoints + Task 9's `admin.js`.
- Guest countdown, no "guest" labeling on the main page → Task 5.
- Reaper enforces the limit on a schedule, LaunchTime-based → Task 7.
- Network stack split, applied once → Tasks 11, 12.
- Baked AMI eliminates the image-pull boot cost → Task 13.
