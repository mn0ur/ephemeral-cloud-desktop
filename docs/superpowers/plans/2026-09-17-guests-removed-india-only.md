# Plan A: Guests Removed, India Only — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only admins and permanent users can use the app; everyone who can use it always keeps their files; and the only region is ap-south-1.

**Architecture:** The panel is the enforcement point, as it already is for OS and region: a signed-in account without access gets a plain message and no Start button, and `/api/dispatch` refuses a start it did not authorise. Guest-only concepts (time limit, "keep my files" choice, `is_guest` tagging, the reaper's time-limit destruction) are removed rather than left inert, so the sleeping-machines work in Plan B has half as many branches to reason about.

**Tech Stack:** Node 22 ESM serverless functions on Vercel, `node:test`, Upstash Redis, GitHub Actions, Terraform, browser-classic JS (no build step) for `panel/public`.

**Spec:** `docs/superpowers/specs/2026-09-17-sleeping-machines-design.md` (sections "Guests removed" and the ap-south-1 decision; Plans B and C implement the rest)

## Global Constraints

- The repo is PUBLIC: never route a secret through a `workflow_dispatch` input, and never print a secret into a log or a report.
- The panel holds no AWS or Terraform credentials. All AWS action happens in workflows.
- Never test under a real user's username. Use a throwaway (`sddtest`).
- Do not delete anyone's data volume. Existing guest volumes stay.
- Region is `ap-south-1`, AZ suffix `c`.
- Panel tests run with `cd panel && npm test`; every touched `.js` must pass `node --check`; workflows must parse as YAML; `terraform fmt -check -recursive terraform` must be clean.
- Commit after each task. Branch: `feat/no-guests-india-only` off `main`.

---

### Task 1: The panel refuses a start for an account without access

**Files:**
- Modify: `panel/lib/desktops.js` (add `startRefusalReason`)
- Modify: `panel/lib/auth.js:45-55` (`sessionFromRequest`: add `has_access`)
- Modify: `panel/api/dispatch.js:26-60` (use it; persist always true; drop `is_guest`)
- Test: `panel/test/desktops.test.js`

**Interfaces:**
- Consumes: `sessionPhase` (existing, `panel/lib/desktops.js`).
- Produces: `startRefusalReason(session, existingSession) -> string | null` — the message to show, or null when the start may proceed. `session.has_access: boolean` on every session object.

- [ ] **Step 1: Write the failing test**

Append to `panel/test/desktops.test.js`:

```js
test("startRefusalReason: only accounts with access may start, and only one desktop each", () => {
  const ok = { has_access: true, is_admin: false };
  assert.equal(startRefusalReason(ok, null), null);
  assert.equal(
    startRefusalReason({ has_access: false, is_admin: false }, null),
    "Your account doesn't have access to Sihaab yet. Ask the owner to add you."
  );
  // an admin always has access
  assert.equal(startRefusalReason({ has_access: true, is_admin: true }, null), null);
  // already running or starting: one desktop per person
  for (const status of ["pending", "ready", "active"]) {
    assert.equal(startRefusalReason(ok, { status }), "you already have a desktop running");
  }
  // a finished/errored session is not in the way
  assert.equal(startRefusalReason(ok, { status: "error" }), null);
  assert.equal(startRefusalReason(undefined, null), "sign in first");
});
```

Add `startRefusalReason` to the import list at the top of that file.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd panel && npm test`
Expected: FAIL — `does not provide an export named 'startRefusalReason'`

- [ ] **Step 3: Write minimal implementation**

In `panel/lib/desktops.js`, after `requestedOs`:

```js
// Guests were removed on 2026-09-17: only an admin or a permanent user may
// start a desktop. The client hides the button, but this is the enforcement
// point - the client is only a hint, same rule as os and region.
export const NO_ACCESS_MESSAGE =
  "Your account doesn't have access to Sihaab yet. Ask the owner to add you.";

export function startRefusalReason(session, existingSession) {
  if (!session) return "sign in first";
  if (!session.has_access) return NO_ACCESS_MESSAGE;
  if (["pending", "ready", "active"].includes(existingSession?.status)) {
    return "you already have a desktop running";
  }
  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd panel && npm test`
Expected: PASS (all tests)

- [ ] **Step 5: Wire it into auth and dispatch**

In `panel/lib/auth.js`, inside `sessionFromRequest`, replace the two lines that set `is_admin`/`can_persist` with:

```js
  const admin = await isAdmin(payload.email);
  payload.is_admin = admin;
  // Guests removed 2026-09-17: access and persistence are the same thing now -
  // everyone who may use the app keeps their files.
  payload.has_access = admin || (await isPermanentUser(payload.email));
  payload.can_persist = payload.has_access;
```

In `panel/api/dispatch.js`, in the `action === "start"` branch, replace the `live.includes(...)` check and the `persist` line:

```js
    const refusal = startRefusalReason(session, sessions[me]);
    if (refusal) {
      return res.status(refusal === NO_ACCESS_MESSAGE ? 403 : 409).json({ error: refusal });
    }
    // Everyone who can start is a permanent user: files are always kept.
    const persist = true;
```

and in the `dispatch(workflow, {...})` call replace `is_guest: session.can_persist ? "false" : "true",` with `is_guest: "false",`.

Update the import at the top of `panel/api/dispatch.js`:

```js
import { activeCount, MAX_CONCURRENT, requestedOs, requestedRegion, startRefusalReason, NO_ACCESS_MESSAGE } from "../lib/desktops.js";
```

- [ ] **Step 6: Verify nothing else reads the removed behaviour**

Run: `cd panel && grep -rn "can_persist\|is_guest" --include=*.js . | grep -v node_modules`
Expected: only `auth.js` (setting it), `app.js:142` (Task 2 removes it), `dispatch.js` (`is_guest: "false"`), and `session-ready.js` (reads `prior.is_guest`, harmless).

Run: `cd panel && npm test && for f in api/*.js api/admin/*.js lib/*.js public/*.js; do node --check $f || echo BAD $f; done`
Expected: tests pass, no BAD lines.

- [ ] **Step 7: Commit**

```bash
git add panel/lib/desktops.js panel/lib/auth.js panel/api/dispatch.js panel/test/desktops.test.js
git commit -m "Only admins and permanent users may start a desktop"
```

---

### Task 2: The page shows a no-access message instead of a Start button

**Files:**
- Modify: `panel/api/status.js` (send `has_access`)
- Modify: `panel/public/app.js:120-160` (no-access card; remove the persist checkbox)
- Test: browser check with mocked status (no unit test — this is rendering)

**Interfaces:**
- Consumes: `session.has_access` from `/api/status`.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Send has_access to the page**

`sessionFromRequest` already puts `has_access` on the session object that `status.js` returns as `session`, so no change is needed in `status.js`. Verify it arrives:

Run: `cd panel && grep -n "session," api/status.js`
Expected: the `out` object contains `session,` — the whole payload including `has_access`.

- [ ] **Step 2: Replace the persist checkbox and gate the Start card**

In `panel/public/app.js`, inside `renderMine`, in the no-session branch, replace the `persistLabel` constant and its use:

```js
    // Guests removed 2026-09-17: everyone who can start keeps their files, so
    // there is no choice to offer. An account without access gets told so
    // plainly instead of a button that would fail.
    if (!session.has_access) {
      box.innerHTML =
        '<div class="status"><span class="dot"></span> No access yet</div>' +
        '<div class="sub">Your account isn\'t enabled for Sihaab yet. Ask the owner to add you, then sign in again.</div>';
      return;
    }
```

Place this immediately after `lastPhase = null;` in that branch, and delete both the `const persistLabel = ...` declaration and the `${persistLabel}` line from the `box.innerHTML` template.

In `go()`, delete the line `body.persist = $("persist")?.checked || false;`.

- [ ] **Step 3: Check both states render**

Run: `cd panel && node --check public/app.js && python3 -m http.server 8799 --bind 0.0.0.0 --directory public &`

In the preview browser, override `window.fetch` to return a status payload with `session.has_access = false` and `my_session: null`, call `poll()`, and confirm the card reads "No access yet" with no buttons. Repeat with `has_access: true` and confirm the OS selector and "Start my desktop" appear and there is no "Keep my files" checkbox.

Expected: exactly that; no console errors. Stop the server by PID afterwards (never `pkill -f`, which kills the agent's own shell).

- [ ] **Step 4: Commit**

```bash
git add panel/public/app.js
git commit -m "Page: no-access card, and no keep-my-files choice"
```

---

### Task 3: Workflows and reaper stop treating anyone as a guest

**Files:**
- Modify: `.github/workflows/desktop-up.yml:57-60` (`is_guest` input description), `:67` (`os` description already updated)
- Modify: `.github/workflows/desktop-reaper.yml` (remove time-limit destruction)
- Modify: `panel/api/admin/config.js`, `panel/public/admin.js:60-75,120-130` (remove the guest-limit control)
- Test: YAML parse + `bash -n` on changed run blocks

**Interfaces:**
- Consumes: nothing.
- Produces: `desktop-reaper.yml` no longer destroys anything; Plan C gives it the parking job.

- [ ] **Step 1: Make the reaper report instead of destroy**

Replace the whole `Discover every live guest desktop, destroy anything past the limit` step in `.github/workflows/desktop-reaper.yml` with:

```yaml
      - name: Report any desktop that is running
        run: |
          # Guests were removed on 2026-09-17, so there is no time limit left to
          # enforce and this workflow destroys nothing. It stays as a cheap
          # visibility pass until Plan C gives it the job of parking machines
          # that are running with nobody connected.
          set -uo pipefail
          ROWS=$(aws ec2 describe-instances --region ap-south-1 \
            --filters "Name=tag:Stack,Values=desktop" "Name=instance-state-name,Values=running,pending" \
            --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Owner`]|[0].Value,LaunchTime]' \
            --output text)
          if [ -z "$ROWS" ]; then
            echo "no desktops running"
          else
            echo "$ROWS"
          fi
```

Also delete the now-unused `HUB_CALLBACK_SECRET`/`PANEL_URL`/`CLOUDFLARE_API_TOKEN` env block on that step and the `hashicorp/setup-terraform` step, since nothing here runs Terraform any more.

- [ ] **Step 2: Verify the workflow still parses and its script is valid**

Run:
```bash
python3 -c "import yaml;yaml.safe_load(open('.github/workflows/desktop-reaper.yml'));print('yaml ok')"
python3 - <<'PY'
import yaml,re,subprocess
wf=yaml.safe_load(open(".github/workflows/desktop-reaper.yml"))
for st in wf["jobs"]["reap"]["steps"]:
    if "run" in st:
        r=subprocess.run(["bash","-n"],input=re.sub(r"\$\{\{[^}]*\}\}","X",st["run"]),text=True,capture_output=True)
        print(st.get("name"), "OK" if r.returncode==0 else r.stderr)
PY
```
Expected: `yaml ok` and OK for every step.

- [ ] **Step 3: Update the is_guest input description**

In `.github/workflows/desktop-up.yml`, replace the `is_guest` description with:

```yaml
        description: "Legacy: guests were removed 2026-09-17 and the panel always sends false. Kept so an old dispatch by hand still validates; true only adds the Role=guest-desktop tag."
```

- [ ] **Step 4: Remove the guest-limit control from the admin console**

In `panel/public/admin.js`, delete the limit save handler (the block containing `guest_limit_minutes` in its `JSON.stringify` body, wired to `#limit-save`) and the line `if (document.activeElement !== $("limit-input")) $("limit-input").value = s.guest_limit_minutes;`.

In `panel/public/admin.html`, delete the whole Guests card — `panel/public/admin.html:61-67`, from `<div class="kicker">Guests</div>` through the `<div class="sub" ...>Minutes before a guest session is auto-destroyed.</div>` line, including the `#limit-input` and `#limit-save` row and the card element wrapping them.

Leave `panel/api/admin/config.js` and `getGuestLimitMinutes` in place: Plan C reuses that endpoint for the idle timeout, and removing it now would be churn.

- [ ] **Step 5: Verify**

Run: `cd panel && node --check public/admin.js && npm test`
Expected: passes, no reference to `limit-input` remains:
`grep -rn "limit-input\|guest_limit" public/ | grep -v node_modules` → no hits in `public/`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/desktop-reaper.yml .github/workflows/desktop-up.yml panel/public/admin.js panel/public/admin.html
git commit -m "Reaper stops destroying by time limit; admin loses the guest limit"
```

---

### Task 4: One region, no branching

**Files:**
- Modify: `panel/lib/desktops.js` (`requestedRegion`)
- Modify: `panel/api/dispatch.js` (call it without `is_admin`)
- Modify: `.github/workflows/desktop-up.yml`, `desktop-down.yml` (AZ mapping and state key)
- Test: `panel/test/desktops.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces: `requestedRegion(bodyRegion) -> "ap-south-1"` (single argument now). **Plan B changes the state key again**, to `desktop/user-<name>/<os>/terraform.tfstate`; this task only removes the region branch.

- [ ] **Step 1: Write the failing test**

Replace the existing `requestedRegion` assertions in `panel/test/desktops.test.js` with:

```js
test("requestedRegion: ap-south-1 is the only region, whatever is asked for", () => {
  assert.equal(requestedRegion("ap-south-1"), "ap-south-1");
  assert.equal(requestedRegion("me-central-1"), "ap-south-1");
  assert.equal(requestedRegion(undefined), "ap-south-1");
  assert.deepEqual(Object.keys(REGIONS), ["ap-south-1"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd panel && npm test`
Expected: FAIL — `requestedRegion("me-central-1")` returns `"me-central-1"` under the old two-argument signature (the first argument is read as `isAdmin`).

- [ ] **Step 3: Write minimal implementation**

In `panel/lib/desktops.js` replace `requestedRegion`:

```js
// One region: India (ap-south-1). UAE was removed 2026-09-13 (AWS throttles
// every launch there for this account) and the owner confirmed 2026-09-17
// that this app uses India only. Kept as a function, not a constant, because
// the session records the region it ran in and a second region would return
// here rather than in every caller.
export function requestedRegion(bodyRegion) {
  return Object.prototype.hasOwnProperty.call(REGIONS, bodyRegion) ? bodyRegion : "ap-south-1";
}
```

In `panel/api/dispatch.js` replace the call:

```js
    const region = requestedRegion(req.body?.region);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd panel && npm test`
Expected: PASS

- [ ] **Step 5: Drop the region branch from both workflows**

In `.github/workflows/desktop-up.yml` and `.github/workflows/desktop-down.yml`, replace the `Map region to its AZ suffix` step's `run:` body with:

```yaml
          # One region, one zone: ap-south-1c (cheapest measured zone, and the
          # only region this app uses since 2026-09-17).
          echo "AZ_SUFFIX=c" >> "$GITHUB_ENV"
          echo "AWS_AZ=ap-south-1c" >> "$GITHUB_ENV"
```

In both files, in the stale-lock step and the terraform step, delete the `if [ "${{ inputs.region }}" != "ap-south-1" ]; then KEY=...; fi` blocks, leaving the single-line `KEY="desktop/user-${{ inputs.guest_username }}/terraform.tfstate"`.

- [ ] **Step 6: Verify both workflows**

Run:
```bash
python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')];print('yaml ok')"
grep -rn "me-central-1" .github/workflows/ panel/lib panel/api | grep -v "tfstate\|backend\|^.*#"
```
Expected: `yaml ok`; the only remaining `me-central-1` mentions are the S3 backend's region (the state bucket genuinely lives there) and comments.

- [ ] **Step 7: Commit**

```bash
git add panel/lib/desktops.js panel/api/dispatch.js panel/test/desktops.test.js .github/workflows/desktop-up.yml .github/workflows/desktop-down.yml
git commit -m "One region: drop the region branch from panel and workflows"
```

---

### Task 5: Prove it end to end, then ship

**Files:**
- None changed (verification only; fixes land in the task they belong to)

**Interfaces:**
- Consumes: everything above.
- Produces: a merged, deployed `main` that Plan B builds on.

- [ ] **Step 1: Full local verification**

Run:
```bash
cd panel && npm test
for f in api/*.js api/admin/*.js lib/*.js public/*.js; do node --check $f || echo BAD $f; done
cd .. && python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')];print('yaml ok')"
terraform fmt -check -recursive terraform && echo "fmt ok"
```
Expected: tests pass, no BAD, `yaml ok`, `fmt ok`.

- [ ] **Step 2: Open the PR and get it reviewed**

```bash
git push -u origin feat/no-guests-india-only
gh pr create --base main --title "Guests removed, India only" --body "Implements Plan A of docs/superpowers/specs/2026-09-17-sleeping-machines-design.md"
```

Dispatch an independent review of the diff (as was done for PR #31 and #32) covering: can a signed-in account without access still reach a start by any path; does the reaper still destroy anything; does any code still read `can_persist` or a guest time limit; does the state key in `desktop-up.yml` still match `desktop-down.yml` exactly. Fix Critical and Important findings before merging.

- [ ] **Step 3: Merge and confirm the deploy**

```bash
gh pr merge --squash --delete-branch
```
Then poll the Vercel production deployment for that merge commit until `READY`, and check live:
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://desktop.sihaab.com/
curl -s https://desktop.sihaab.com/app.js | grep -c "No access yet"
```
Expected: `200`, and `1`.

- [ ] **Step 4: Real end-to-end start and destroy under a throwaway username**

This is the task's real gate: Plan A touches the dispatch path, so a start must still work.

With the `sddtest` account (never a real user's), from the panel: Start Linux, watch it reach Running, open it, then Destroy. Confirm in the run logs that `is_guest=false`, the state key has no region segment, and the AZ is `ap-south-1c`.

Expected: start succeeds in roughly today's ~3 minutes, the desktop answers, destroy leaves nothing running:
```bash
aws ec2 describe-instances --region ap-south-1 --filters "Name=tag:Stack,Values=desktop" "Name=instance-state-name,Values=running,pending" --query 'length(Reservations[].Instances[])'
```
Expected: `0`.

- [ ] **Step 5: Tell the owner what changed and what to check**

Report: who can now sign in and use it, what an account without access sees, that the guest time limit is gone, and that region selection is gone. Ask them to confirm a second Google account without access shows the no-access card.

---

## Follow-up plans

Written after this plan is executed, each from the same spec:

- **Plan B — sleeping machines core.** Per-OS machine registry in Redis, state key and concurrency per user+OS, `desktop-sleep.yml` and `desktop-wake.yml`, the `building`/`waking` phases and cards, build-both-on-sign-in with a one-shot claim, one running machine per user, "End session" vs "Delete machine".
- **Plan C — auto-sleep and the machine list.** On-machine idle watchers for both OSes reusing the per-session token, `/api/session-idle`, the panel-side no-probe backstop, the admin idle-timeout setting, and the admin machines list with per-row Delete.
