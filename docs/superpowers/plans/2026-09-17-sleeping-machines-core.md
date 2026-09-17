# Plan B: Sleeping Machines Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every permanent user has two machines — one Linux, one Windows — parked (EC2 stopped) when unused, so Start wakes one in ~1 minute instead of building one in ~3.

**Architecture:** A **machine** outlives a session and lives in a new Redis hash `machines`, keyed `<username>:<os>`. Sleep and wake are plain EC2 stop/start in two new slim workflows (no Terraform); only delete runs `terraform destroy`. The panel drives every transition: a finished build reports ready and the panel parks it unless the user asked for it; an OS switch sleeps the running machine and wakes the other when the sleep reports back. Terraform state and workflow concurrency become per user AND OS so the two machines never block or overwrite each other.

**Tech Stack:** Node 22 ESM serverless on Vercel, `node:test`, Upstash Redis, GitHub Actions, Terraform, AWS EC2 (ap-south-1), browser-classic JS for `panel/public`.

**Spec:** `docs/superpowers/specs/2026-09-17-sleeping-machines-design.md` (Plan A shipped in PR #33; Plan C is auto-sleep + the admin machine list)

## Global Constraints

- The repo is PUBLIC: never route a secret through a `workflow_dispatch` input, never print a secret into a log or report.
- The panel holds no AWS or Terraform credentials. Every AWS action happens inside a workflow.
- Never test under a real user's username. Use `sddtest`.
- Never delete a user's data volume. Delete-machine destroys the machine only.
- Region is `ap-south-1`, AZ `ap-south-1c`. The Terraform state **bucket** is in `me-central-1` — that is correct, leave it.
- **Parked machines must be on-demand.** A spot instance cannot be stopped and resumed. Every machine this plan creates is on-demand (`use_spot=false`).
- Terraform state key: `desktop/user-<username>/<os>/terraform.tfstate`, built identically in every workflow that touches it.
- Workflow concurrency group: `desktop-lifecycle-<username>-<os>`, identical in up/down/sleep/wake.
- `cd panel && npm test` passes; `node --check` every touched .js; workflows parse as YAML; `bash -n` every changed run block; `terraform fmt -check -recursive terraform` clean.
- Commit after each task. Branch: `feat/sleeping-machines` off `main`.

---

### Task 1: The machine registry

**Files:**
- Create: `panel/lib/machines.js`
- Modify: `panel/lib/state.js` (Redis hash `machines`)
- Test: `panel/test/machines.test.js`

**Interfaces:**
- Produces, from `panel/lib/machines.js`:
  - `MACHINE_OSES = ["linux", "windows"]`
  - `machineKey(username, os) -> "<username>:<os>"`
  - `startPlan(machines, username, os) -> { action, sleepOs }` where `action` is `"build" | "wake" | "adopt"` and `sleepOs` is the OS of a machine that must be slept first, or `null`
  - `missingOses(machines, username) -> string[]`
- Produces, from `panel/lib/state.js`: `loadMachines()`, `putMachine(username, os, machine)`, `dropMachine(username, os)`.
- Machine record shape (written by later tasks): `{ os, state, instance_id, hostname, created_at, last_woken_at, lost_token_hash }` with `state` one of `"building" | "sleeping" | "running"`.

- [ ] **Step 1: Write the failing test**

Create `panel/test/machines.test.js`:

```js
import test from "node:test";
import assert from "node:assert/strict";
import { MACHINE_OSES, machineKey, startPlan, missingOses } from "../lib/machines.js";

const m = (state, os) => ({ os, state, instance_id: "i-1" });

test("machineKey: one machine per user per OS", () => {
  assert.equal(machineKey("alice", "linux"), "alice:linux");
  assert.equal(machineKey("alice", "windows"), "alice:windows");
  assert.deepEqual(MACHINE_OSES, ["linux", "windows"]);
});

test("startPlan: build when there is no machine, wake when it sleeps, adopt when it already runs", () => {
  assert.deepEqual(startPlan({}, "alice", "linux"), { action: "build", sleepOs: null });
  assert.deepEqual(
    startPlan({ "alice:linux": m("sleeping", "linux") }, "alice", "linux"),
    { action: "wake", sleepOs: null }
  );
  assert.deepEqual(
    startPlan({ "alice:linux": m("running", "linux") }, "alice", "linux"),
    { action: "adopt", sleepOs: null }
  );
  // a machine still being built is not ready to wake: the panel waits, it does not build twice
  assert.deepEqual(
    startPlan({ "alice:linux": m("building", "linux") }, "alice", "linux"),
    { action: "adopt", sleepOs: null }
  );
});

test("startPlan: only one machine runs at a time, so the other OS is slept first", () => {
  const machines = {
    "alice:linux": m("running", "linux"),
    "alice:windows": m("sleeping", "windows"),
  };
  assert.deepEqual(startPlan(machines, "alice", "windows"), { action: "wake", sleepOs: "linux" });
  // someone else's running machine never forces a sleep
  const others = { "bob:linux": m("running", "linux"), "alice:windows": m("sleeping", "windows") };
  assert.deepEqual(startPlan(others, "alice", "windows"), { action: "wake", sleepOs: null });
  // building the second OS while the first runs also sleeps the first
  assert.deepEqual(
    startPlan({ "alice:linux": m("running", "linux") }, "alice", "windows"),
    { action: "build", sleepOs: "linux" }
  );
});

test("missingOses: which machines a user still needs built", () => {
  assert.deepEqual(missingOses({}, "alice"), ["linux", "windows"]);
  assert.deepEqual(missingOses({ "alice:linux": m("sleeping", "linux") }, "alice"), ["windows"]);
  assert.deepEqual(
    missingOses({ "alice:linux": m("sleeping", "linux"), "alice:windows": m("running", "windows") }, "alice"),
    []
  );
  // another user's machines are not this user's
  assert.deepEqual(missingOses({ "bob:linux": m("sleeping", "linux") }, "alice"), ["linux", "windows"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd panel && node --test test/machines.test.js`
Expected: FAIL — cannot find module `../lib/machines.js`

- [ ] **Step 3: Write minimal implementation**

Create `panel/lib/machines.js`:

```js
// A MACHINE outlives a session. Each permanent user has two - one Linux, one
// Windows - parked (EC2 stopped) when unused, because a stopped machine costs
// only its disk (~$4/month Windows, ~$2.50 Linux) and starts in ~40-60s
// instead of the ~3 minutes a build takes.
//
// Sessions say "someone is using a desktop right now"; machines say "this
// person has a desktop that exists". Keeping them apart is what lets Start
// become a wake.

export const MACHINE_OSES = ["linux", "windows"];

export function machineKey(username, os) {
  return `${username}:${os}`;
}

export function missingOses(machines, username) {
  return MACHINE_OSES.filter((os) => !machines[machineKey(username, os)]);
}

// What Start should do, and whether the user's OTHER machine has to be put to
// sleep first. Only one machine per user runs at a time, so nobody can run up
// two hourly bills at once (spec decision, 2026-09-17).
export function startPlan(machines, username, os) {
  const mine = machines[machineKey(username, os)];
  const otherOs = MACHINE_OSES.find((o) => o !== os);
  const other = machines[machineKey(username, otherOs)];
  const sleepOs = other && other.state === "running" ? otherOs : null;

  // "building" is not "ready to wake" and not "nothing there": a second
  // dispatch would build a duplicate machine, so the page waits instead.
  if (!mine) return { action: "build", sleepOs };
  if (mine.state === "sleeping") return { action: "wake", sleepOs };
  return { action: "adopt", sleepOs };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd panel && npm test`
Expected: PASS, all tests (the existing 12 plus the 4 new).

- [ ] **Step 5: Add the Redis store**

In `panel/lib/state.js`, add `machines: "machines",` to the `K` map with the comment `// hash: "<username>:<os>" -> machine JSON`, then append:

```js
// -- machines ---------------------------------------------------------------

// Separate from sessions on purpose: a machine survives the session that used
// it, and a session must never be able to delete the machine record by being
// rewritten (that class of bug cost a Destroy in PR #32's review).
export async function loadMachines() {
  const raw = (await requireRedis().hgetall(K.machines)) || {};
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    out[k] = typeof v === "string" ? JSON.parse(v) : v;
  }
  return out;
}

export async function putMachine(username, os, machine) {
  await requireRedis().hset(K.machines, { [machineKey(username, os)]: JSON.stringify(machine) });
}

export async function dropMachine(username, os) {
  await requireRedis().hdel(K.machines, machineKey(username, os));
}
```

Add `import { machineKey } from "./machines.js";` at the top of `state.js`. Verify no import cycle: `machines.js` must import nothing.

- [ ] **Step 6: Verify**

Run: `cd panel && npm test && node --check lib/state.js && node --check lib/machines.js && node -e "import('./lib/state.js').then(()=>console.log('imports ok'))"`
Expected: tests pass, `imports ok`.

- [ ] **Step 7: Commit**

```bash
git add panel/lib/machines.js panel/lib/state.js panel/test/machines.test.js
git commit -m "Machine registry: one machine per user per OS"
```

---

### Task 2: Per-OS Terraform state and concurrency

**Files:**
- Modify: `.github/workflows/desktop-up.yml` (concurrency group, 2 KEY sites, `use_spot` default)
- Modify: `.github/workflows/desktop-down.yml` (concurrency group, 2 KEY sites)

**Interfaces:**
- Produces: state key `desktop/user-<username>/<os>/terraform.tfstate` and concurrency group `desktop-lifecycle-<username>-<os>`, both consumed by Tasks 3 and 4.

- [ ] **Step 1: Change the state key in both workflows**

There are FOUR places that build the key (stale-lock step and terraform step, in each of the two files). Every one becomes:

```bash
          KEY="desktop/user-${{ inputs.guest_username }}/${{ inputs.os }}/terraform.tfstate"
```

In the terraform steps, the owner's fallback stays as it is (`KEY="desktop/terraform.tfstate"` when `guest_username` is empty); only the per-user line gains `/${{ inputs.os }}`.

Add above each: `# Per user AND per OS: a user has one Linux and one Windows machine, and one OS's apply must never overwrite the other's state.`

- [ ] **Step 2: Change the concurrency group in both workflows**

```yaml
concurrency:
  # Per username AND OS: a user's Windows and Linux machines are independent,
  # so a Windows start must not queue behind a Linux one. Two runs for the SAME
  # machine still serialise, which is what protects the state lock.
  group: desktop-lifecycle-${{ inputs.guest_username }}-${{ inputs.os }}
  cancel-in-progress: false
```

- [ ] **Step 3: Default to on-demand**

In `.github/workflows/desktop-up.yml`, change the `use_spot` input default to `false` and replace its description with:

```yaml
        description: "Spot cannot be stopped and resumed, only terminated - and every machine this panel builds is parked when unused. Default false. true is for a throwaway machine that will never sleep."
```

- [ ] **Step 4: Verify both workflows**

Run:
```bash
python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')];print('yaml ok')"
grep -n 'KEY="desktop' .github/workflows/desktop-up.yml .github/workflows/desktop-down.yml
grep -n 'group: desktop-lifecycle' .github/workflows/*.yml
```
Expected: `yaml ok`; the four per-user KEY lines are byte-identical to each other; both concurrency groups are byte-identical.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/desktop-up.yml .github/workflows/desktop-down.yml
git commit -m "State key and concurrency per user AND OS; build on-demand"
```

---

### Task 3: The sleep workflow

**Files:**
- Create: `.github/workflows/desktop-sleep.yml`
- Create: `panel/api/session-slept.js`
- Modify: `panel/lib/github.js` (add `sleep` to `WORKFLOWS`)

**Interfaces:**
- Consumes: `putMachine`, `loadMachines` (Task 1); state key rules (Task 2).
- Produces: workflow `desktop-sleep.yml` with inputs `guest_username` (required), `os` (choice linux/windows); endpoint `POST /api/session-slept` authenticated with `HUB_CALLBACK_SECRET`, body `{username, os}`; `WORKFLOWS.sleep = "desktop-sleep.yml"`.

- [ ] **Step 1: Write the sleep workflow**

Create `.github/workflows/desktop-sleep.yml`:

```yaml
name: Desktop - SLEEP
# One label per user and OS: the panel shows a user ONLY their own run and
# matches on this name (panel/lib/desktops.js runBelongsTo).
run-name: "Desktop - SLEEP · ${{ inputs.guest_username }} · ${{ inputs.os }}"

# Stops the machine; it is NOT destroyed. The root disk, installed apps and
# settings all survive, which is the whole point: the next Start is a ~1 minute
# wake instead of a ~3 minute build. Terraform is never run here - the machine
# stays in its state file exactly as it is.
on:
  workflow_dispatch:
    inputs:
      guest_username:
        description: "Whose machine to put to sleep."
        required: true
      os:
        description: "Which of that user's two machines."
        type: choice
        options: [linux, windows]
        default: linux

permissions:
  contents: read

concurrency:
  group: desktop-lifecycle-${{ inputs.guest_username }}-${{ inputs.os }}
  cancel-in-progress: false

jobs:
  sleep:
    name: stop the machine
    runs-on: ubuntu-latest
    timeout-minutes: 10
    env:
      AWS_REGION: ap-south-1

    steps:
      - uses: actions/checkout@v4

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

      - name: Stop the machine and park its hostname
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          HUB_CALLBACK_SECRET: ${{ secrets.HUB_CALLBACK_SECRET }}
          PANEL_URL: ${{ vars.PANEL_URL || 'https://desktop.sihaab.com' }}
          CF_ZONE: sihaab.com
        run: |
          set -uo pipefail
          USER_NAME="${{ inputs.guest_username }}"
          OS="${{ inputs.os }}"

          # Find this user's machine by tag. Owner+OS is unique: one machine per
          # user per OS (panel/lib/machines.js).
          ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Owner,Values=$USER_NAME" "Name=tag:OS,Values=$OS" \
              "Name=tag:Stack,Values=desktop" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
            --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null || true)
          if [ -z "$ID" ] || [ "$ID" = "None" ]; then
            echo "::warning::no $OS machine found for $USER_NAME - nothing to stop"
          else
            echo "stopping $ID"
            aws ec2 stop-instances --instance-ids "$ID" >/dev/null
            aws ec2 wait instance-stopped --instance-ids "$ID" || echo "::warning::stop did not confirm within the wait; the panel is told anyway"
          fi

          # Park the hostname on an unroutable address while the machine sleeps,
          # so the name never points at whatever takes that IP next.
          HOST="$USER_NAME.desktop.sihaab.com"
          [ "$OS" = "windows" ] && HOST="$USER_NAME-desktop.sihaab.com"
          bash scripts/set-dns.sh "$HOST" 192.0.2.1 "$CF_ZONE" false || echo "::warning::DNS park failed for $HOST"

          if [ -n "$HUB_CALLBACK_SECRET" ]; then
            curl -fsS -X POST "$PANEL_URL/api/session-slept" \
              -H "Authorization: Bearer $HUB_CALLBACK_SECRET" \
              -H "Content-Type: application/json" \
              -d "{\"username\":\"$USER_NAME\",\"os\":\"$OS\"}" \
              || echo "::warning::callback failed - the machine IS stopped; the panel will catch up on its next probe"
          fi
```

**Check the Windows hostname rule against `terraform/main.tf`'s `local.effective_hostname` before committing** and make this match it exactly; if it differs, use whatever main.tf produces and say so in your report.

- [ ] **Step 2: Verify the workflow parses and its script is valid**

Run:
```bash
python3 -c "import yaml;yaml.safe_load(open('.github/workflows/desktop-sleep.yml'));print('yaml ok')"
python3 - <<'PY'
import yaml,re,subprocess
wf=yaml.safe_load(open(".github/workflows/desktop-sleep.yml"))
for st in wf["jobs"]["sleep"]["steps"]:
    if "run" in st:
        r=subprocess.run(["bash","-n"],input=re.sub(r"\$\{\{[^}]*\}\}","X",st["run"]),text=True,capture_output=True)
        print(st.get("name"), "OK" if r.returncode==0 else r.stderr)
PY
```
Expected: `yaml ok`, OK for both steps.

- [ ] **Step 3: Write the endpoint**

Create `panel/api/session-slept.js`:

```js
import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { loadMachines, putMachine, dropSession, logEvent } from "../lib/state.js";
import { machineKey } from "../lib/machines.js";

// Called by desktop-sleep.yml once the machine is stopped. The machine RECORD
// survives - that is the difference between sleeping and being destroyed - but
// the session is over.
export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  const os = req.body?.os === "windows" ? "windows" : "linux";
  if (!username) return res.status(400).json({ error: "bad username" });

  const machines = await loadMachines();
  const prior = machines[machineKey(username, os)];
  if (prior) await putMachine(username, os, { ...prior, state: "sleeping", slept_at: Date.now() / 1000 });
  await dropSession(username);
  await logEvent("slept", { username, os });
  return res.status(200).json({ ok: true });
}
```

- [ ] **Step 4: Register the workflow**

In `panel/lib/github.js`, add to `WORKFLOWS`:

```js
  // Stops a machine without destroying it (Plan B). Its opposite is wake.
  sleep: "desktop-sleep.yml",
  wake: "desktop-wake.yml",
```

- [ ] **Step 5: Verify**

Run: `cd panel && node --check api/session-slept.js && node --check lib/github.js && npm test`
Expected: passes.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/desktop-sleep.yml panel/api/session-slept.js panel/lib/github.js
git commit -m "Sleep workflow: stop the machine, park its hostname, keep the record"
```

---

### Task 4: The wake workflow

**Files:**
- Create: `.github/workflows/desktop-wake.yml`
- Modify: `panel/api/session-ready.js` (accept a wake's callback; record the machine)

**Interfaces:**
- Consumes: state key and concurrency rules (Task 2); `putMachine` (Task 1).
- Produces: workflow `desktop-wake.yml` with inputs `guest_username` (required), `os` (choice). It posts the existing `/api/session-ready` with `{username, url, password, login_user, os, region, launched_at, market, instance_id, woken: true}`.

- [ ] **Step 1: Write the wake workflow**

Create `.github/workflows/desktop-wake.yml` with this header:

```yaml
name: Desktop - WAKE
run-name: "Desktop - WAKE · ${{ inputs.guest_username }} · ${{ inputs.os }}"

# Starts a machine that was stopped, repoints its hostname at the new public IP
# (a stopped instance loses its address) and tells the panel it is ready.
# Terraform is never run here: the machine already exists in its state file.
on:
  workflow_dispatch:
    inputs:
      guest_username:
        description: "Whose machine to wake."
        required: true
      os:
        description: "Which of that user's two machines."
        type: choice
        options: [linux, windows]
        default: linux

permissions:
  contents: read

concurrency:
  group: desktop-lifecycle-${{ inputs.guest_username }}-${{ inputs.os }}
  cancel-in-progress: false

jobs:
  wake:
    name: start the machine
    runs-on: ubuntu-latest
    timeout-minutes: 15
    env:
      AWS_REGION: ap-south-1

    steps:
      - uses: actions/checkout@v4

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
```

and this as its working step:

```yaml
      - name: Start the machine, repoint DNS, tell the panel
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          HUB_CALLBACK_SECRET: ${{ secrets.HUB_CALLBACK_SECRET }}
          PANEL_URL: ${{ vars.PANEL_URL || 'https://desktop.sihaab.com' }}
          CF_ZONE: sihaab.com
        run: |
          set -uo pipefail
          USER_NAME="${{ inputs.guest_username }}"
          OS="${{ inputs.os }}"

          ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Owner,Values=$USER_NAME" "Name=tag:OS,Values=$OS" \
              "Name=tag:Stack,Values=desktop" "Name=instance-state-name,Values=stopped,stopping,running,pending" \
            --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null || true)
          if [ -z "$ID" ] || [ "$ID" = "None" ]; then
            # The machine is gone (AWS retirement, or deleted outside the panel).
            # Say so plainly: the panel offers a rebuild rather than showing a
            # wake that will never land.
            echo "::error::no $OS machine found for $USER_NAME - it must be rebuilt"
            exit 1
          fi

          aws ec2 start-instances --instance-ids "$ID" >/dev/null
          aws ec2 wait instance-running --instance-ids "$ID"

          IP=$(aws ec2 describe-instances --instance-ids "$ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
          LAUNCHED_AT=$(date -u +%s)
          if [ -z "$IP" ] || [ "$IP" = "None" ]; then
            echo "::error::machine $ID started but has no public IP"
            exit 1
          fi

          HOST="$USER_NAME.desktop.sihaab.com"
          [ "$OS" = "windows" ] && HOST="$USER_NAME-desktop.sihaab.com"
          bash scripts/set-dns.sh "$HOST" "$IP" "$CF_ZONE" false

          # The password lives on the user's data volume as a tag and does not
          # change when a machine sleeps, so the panel already has it from the
          # build. A wake sends no password; session-ready keeps the prior one.
          if [ -z "$HUB_CALLBACK_SECRET" ]; then
            echo "::error::HUB_CALLBACK_SECRET is not set - the panel cannot learn the desktop is awake."
            exit 1
          fi
          PAYLOAD=$(jq -n \
            --arg username "$USER_NAME" \
            --arg url "https://$HOST" \
            --arg os "$OS" \
            --arg region "ap-south-1" \
            --arg instance_id "$ID" \
            --arg launched_at "$LAUNCHED_AT" \
            '{username:$username, url:$url, os:$os, region:$region, instance_id:$instance_id, launched_at:($launched_at|tonumber), market:"on-demand", woken:true}')
          curl -fsS -X POST "$PANEL_URL/api/session-ready" \
            -H "Authorization: Bearer $HUB_CALLBACK_SECRET" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD"

          {
            echo "## Desktop woken"
            echo ""
            echo "| | |"
            echo "|---|---|"
            echo "| User | \`$USER_NAME\` |"
            echo "| OS | \`$OS\` |"
            echo "| Instance | \`$ID\` |"
            echo "| Address | https://$HOST |"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Keep the password and login user across a wake**

In `panel/api/session-ready.js`, the wake sends no `password`/`login_user`. Change those two fields so a missing value falls back to the prior session's:

```js
    password: req.body?.password || prior.password || null,
    login_user: req.body?.login_user || prior.login_user || null,
```

and record the machine as running. After the existing `putSession(...)` call, add:

```js
  // The machine outlives the session (Plan B). Recording it here - the one
  // place that already knows a machine exists and answers - keeps the registry
  // true for both a fresh build and a wake.
  const machines = await loadMachines();
  const priorMachine = machines[machineKey(username, os)] || {};
  await putMachine(username, os, {
    ...priorMachine,
    os,
    state: "running",
    instance_id: req.body?.instance_id || priorMachine.instance_id || null,
    hostname: (req.body?.url || "").replace(/^https?:\/\//, "") || priorMachine.hostname || null,
    created_at: priorMachine.created_at || Date.now() / 1000,
    last_woken_at: Date.now() / 1000,
    ...(req.body?.session_token ? { lost_token_hash: hashToken(req.body.session_token) } : {}),
  });
```

Add the imports it needs: `loadMachines`, `putMachine` from `../lib/state.js`, `machineKey` from `../lib/machines.js`.

**A wake must not clear the reclaim token hash.** Because the spread carries `priorMachine` first and only overwrites `lost_token_hash` when the callback sends a token, a wake (which sends none) keeps the build's value. Verify that by reading your own code before committing.

- [ ] **Step 3: Verify**

Run:
```bash
python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')];print('yaml ok')"
python3 - <<'PY'
import yaml,re,subprocess
wf=yaml.safe_load(open(".github/workflows/desktop-wake.yml"))
for st in wf["jobs"][list(wf["jobs"])[0]]["steps"]:
    if "run" in st:
        r=subprocess.run(["bash","-n"],input=re.sub(r"\$\{\{[^}]*\}\}","X",st["run"]),text=True,capture_output=True)
        print(st.get("name"), "OK" if r.returncode==0 else r.stderr)
PY
cd panel && node --check api/session-ready.js && npm test
```
Expected: `yaml ok`, OK per step, tests pass.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/desktop-wake.yml panel/api/session-ready.js
git commit -m "Wake workflow: start the machine, repoint DNS, report ready"
```

---

### Task 5: The panel drives build, wake, sleep and delete

**Files:**
- Modify: `panel/api/dispatch.js` (start → build/wake/adopt; `sleep` and `delete` actions)
- Modify: `panel/api/session-ended.js` (delete drops the machine record)
- Modify: `panel/lib/desktops.js` (`sessionPhase`: `building`, `waking`)
- Test: `panel/test/desktops.test.js`, `panel/test/machines.test.js`

**Interfaces:**
- Consumes: `startPlan`, `machineKey` (Task 1); `WORKFLOWS.sleep`, `WORKFLOWS.wake` (Tasks 3-4).
- Produces: `/api/dispatch` accepts `action` of `start | sleep | delete | wipe` (`destroy` stays as an alias of `delete` so an old page keeps working). Session `status` values gain `"building"` and `"waking"`; `sessionPhase` maps them to phases of the same names.

- [ ] **Step 1: Write the failing test for the new phases**

Append to `panel/test/desktops.test.js`:

```js
test("sessionPhase: a first build and a wake are different waits, and neither is 'running'", () => {
  assert.equal(sessionPhase({ status: "building" }), "building");
  assert.equal(sessionPhase({ status: "waking" }), "waking");
  // a sleep in flight reads as destroying-style shutdown, not as running
  assert.equal(sessionPhase({ status: "active", sleep_dispatched_at: 1 }), "sleeping");
  // and an actual delete still wins
  assert.equal(sessionPhase({ status: "active", destroy_dispatched_at: 1, sleep_dispatched_at: 1 }), "destroying");
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd panel && npm test`
Expected: FAIL — `building` currently falls through to `"starting"`.

- [ ] **Step 3: Implement the phases**

In `panel/lib/desktops.js`, in `sessionPhase`, immediately after the `destroy_dispatched_at` line:

```js
  if (s.sleep_dispatched_at) return "sleeping";
  if (s.status === "building") return "building";
  if (s.status === "waking") return "waking";
```

- [ ] **Step 4: Rework the dispatch handler**

In `panel/api/dispatch.js`:

- Import `loadMachines, putMachine` from `../lib/state.js`, and `startPlan, machineKey` from `../lib/machines.js`.
- In the `start` branch, after `startRefusalReason` passes, replace the single build dispatch with:

```js
    const machines = await loadMachines();
    const plan = startPlan(machines, me, os);

    // Only one machine per user runs at a time. Sleep the other one first and
    // remember what to wake when it reports back (api/session-slept dispatches
    // the wake), so the two workflows never have to coordinate with each other.
    if (plan.sleepOs) {
      await dispatch(WORKFLOWS.sleep, { guest_username: me, os: plan.sleepOs });
      await putSession(me, {
        status: "waking", email: session.email, dispatched_at: Date.now() / 1000,
        os, region, pending_wake: true,
      });
      return res.status(202).json({ ok: true, waiting_for: plan.sleepOs });
    }

    if (plan.action === "wake") {
      await putSession(me, {
        status: "waking", email: session.email, dispatched_at: Date.now() / 1000, os, region,
      });
      try {
        await dispatch(WORKFLOWS.wake, { guest_username: me, os });
      } catch (e) {
        await dropSession(me);
        return res.status(e.status || 500).json({ error: e.message });
      }
      return res.status(202).json({ ok: true, action: "wake" });
    }

    if (plan.action === "adopt") {
      // Already building or running - the page just needs to keep polling.
      return res.status(202).json({ ok: true, action: "adopt" });
    }
```

then leave the existing build path (the `putSession` with `status: "pending"` and the `dispatch(workflow, {...})` call) as the `plan.action === "build"` case, with two changes: the session status becomes `"building"`, and the dispatch inputs gain `use_spot: "false"`.

- Add a `sleep` action branch:

```js
  if (action === "sleep") {
    const target = req.body?.username || me;
    if (target !== me && !session.is_admin) return res.status(403).json({ error: "not your session" });
    if (!sessions[target]) return res.status(404).json({ error: "no such session" });
    const os = sessions[target].os || "linux";
    try {
      await dispatch(WORKFLOWS.sleep, { guest_username: target, os });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message });
    }
    await putSession(target, { ...sessions[target], sleep_dispatched_at: Date.now() / 1000 });
    return res.status(202).json({ ok: true });
  }
```

- Rename the existing `destroy` branch to handle `action === "delete" || action === "destroy"`, and after its successful dispatch also mark the machine record: `await putMachine(target, os, { ...(await loadMachines())[machineKey(target, os)], state: "deleting" })` — guarded so it is skipped when there is no record.

- [ ] **Step 5: Delete drops the machine record**

In `panel/api/session-ended.js`, after `dropSession(username)`:

```js
  // A DELETE is the only thing that removes a machine. Sleep keeps the record:
  // that is exactly what makes the next start a ~1 minute wake.
  const os = req.body?.os || prior.os || "linux";
  await dropMachine(username, os);
```

Import `dropMachine` from `../lib/state.js`. In `.github/workflows/desktop-down.yml`, add `\"os\":\"${{ inputs.os }}\"` to the session-ended callback body so the panel drops the right record.

- [ ] **Step 6: Test the sleep-then-wake handoff**

Append to `panel/test/machines.test.js`:

```js
test("startPlan: the OS switch is a sleep then a wake, never two machines running", () => {
  const machines = {
    "alice:linux": { os: "linux", state: "running" },
    "alice:windows": { os: "windows", state: "sleeping" },
  };
  const plan = startPlan(machines, "alice", "windows");
  assert.equal(plan.sleepOs, "linux");
  assert.equal(plan.action, "wake");
  // after the sleep lands, the same call plans a plain wake
  const after = { ...machines, "alice:linux": { os: "linux", state: "sleeping" } };
  assert.deepEqual(startPlan(after, "alice", "windows"), { action: "wake", sleepOs: null });
});
```

- [ ] **Step 7: Verify**

Run: `cd panel && npm test && for f in api/*.js api/admin/*.js lib/*.js public/*.js; do node --check $f || echo BAD $f; done`
Expected: all pass, no BAD.

- [ ] **Step 8: Commit**

```bash
git add panel/api/dispatch.js panel/api/session-ended.js panel/lib/desktops.js panel/test/ .github/workflows/desktop-down.yml
git commit -m "Panel drives build, wake, sleep and delete"
```

---

### Task 6: Sleep dispatches the pending wake, and sign-in builds both machines

**Files:**
- Modify: `panel/api/session-slept.js` (dispatch the pending wake)
- Modify: `panel/api/status.js` (build missing machines on sign-in)
- Test: `panel/test/machines.test.js`

**Interfaces:**
- Consumes: `missingOses` (Task 1), `WORKFLOWS.wake` (Task 4), `claimOnce` (existing, `panel/lib/state.js`).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Finish the OS switch**

In `panel/api/session-slept.js`, before `dropSession(username)`:

```js
  // An OS switch is a sleep followed by a wake. The wake is dispatched HERE,
  // when the first machine is actually stopped, so the panel never has two
  // machines running for one person.
  const sessions = await loadSessions();
  const pending = sessions[username];
  if (pending?.pending_wake && pending.os && pending.os !== os) {
    try {
      await dispatch(WORKFLOWS.wake, { guest_username: username, os: pending.os });
      await putSession(username, {
        status: "waking", email: pending.email, dispatched_at: Date.now() / 1000,
        os: pending.os, region: pending.region || "ap-south-1",
      });
      await logEvent("switch_os", { username, from: os, to: pending.os });
      return res.status(200).json({ ok: true, woke: pending.os });
    } catch (e) {
      // Fall through: the machine IS asleep, and the user can press Start again.
      console.error("pending wake dispatch failed", e.message);
    }
  }
```

Add the imports it needs (`loadSessions`, `putSession`, `logEvent` from state; `dispatch`, `WORKFLOWS` from github).

- [ ] **Step 2: Build both machines on sign-in**

In `panel/api/status.js`, after the session is loaded and `refreshOwn` has run, add:

```js
  // A permanent user's two machines are built the first time they sign in, so
  // that even their first Start is a ~1 minute wake rather than a ~3 minute
  // build. Each build is claimed once, so a refresh or a second tab cannot
  // start duplicates.
  if (session?.has_access && tokenConfigured) {
    const machines = await loadMachines();
    for (const os of missingOses(machines, session.user_id)) {
      if (!(await claimOnce(`build:${session.user_id}:${os}`, 1800))) continue;
      try {
        await dispatch(WORKFLOWS.start, {
          username: session.user_id, guest_username: session.user_id,
          owner_email: session.email, fresh: "false", persist: "true",
          is_guest: "false", use_spot: "false", os, region: "ap-south-1",
        });
        await putMachine(session.user_id, os, {
          os, state: "building", created_at: Date.now() / 1000,
        });
      } catch (e) {
        await releaseClaim(`build:${session.user_id}:${os}`);
        console.error("sign-in build failed", os, e.message);
      }
    }
  }
```

Add the imports. **This runs inside the status poll, which the page calls every 5 seconds — the claim is what stops it building over and over. Confirm by reading `claimOnce` that a failed claim returns false rather than throwing.**

- [ ] **Step 3: Park a freshly built machine**

A build ends with `session-ready`, which marks the machine running. In `panel/api/session-ready.js`, after the machine record is written:

```js
  // Built but not asked for: park it, so the user pays disk and not $0.36/hour
  // for a machine they have not opened. The next Start wakes it in ~1 minute.
  if (!prior.status || prior.status === "building") {
    if (!prior.start_requested) {
      await dispatch(WORKFLOWS.sleep, { guest_username: username, os });
      await putSession(username, { ...(await loadSessions())[username], sleep_dispatched_at: Date.now() / 1000 });
    }
  }
```

and in `panel/api/dispatch.js`'s build path, set `start_requested: true` on the session it writes, so a machine the user actually asked for stays running.

- [ ] **Step 4: Test the claim guard logic**

Append to `panel/test/machines.test.js`:

```js
test("missingOses drives the sign-in build: nothing to build once both exist", () => {
  const building = { "alice:linux": { os: "linux", state: "building" } };
  assert.deepEqual(missingOses(building, "alice"), ["windows"]);
  const both = { ...building, "alice:windows": { os: "windows", state: "building" } };
  assert.deepEqual(missingOses(both, "alice"), []);
});
```

- [ ] **Step 5: Verify**

Run: `cd panel && npm test && for f in api/*.js lib/*.js; do node --check $f || echo BAD $f; done`
Expected: pass, no BAD.

- [ ] **Step 6: Commit**

```bash
git add panel/api/session-slept.js panel/api/status.js panel/api/session-ready.js panel/api/dispatch.js panel/test/machines.test.js
git commit -m "Sign-in builds both machines; a built machine parks itself"
```

---

### Task 7: The page

**Files:**
- Modify: `panel/public/app.js`
- Modify: `panel/api/status.js` (add `has_machines` for Step 4)

**Interfaces:**
- Consumes: phases `building`, `waking`, `sleeping` (Task 5); `/api/dispatch` actions `sleep` and `delete` (Task 5).
- Produces: nothing.

- [ ] **Step 1: Add the two new waits to the progress bar**

In `panel/public/app.js`, `EXPECTED_S` gains:

```js
  wake_linux: 75,
  wake_windows: 120,
```

(keep the existing `linux`, `windows` and `destroy` entries for builds and deletes). In `tickBars`, the verb for a `wake_*` bar is `"Waking"`, and for `sleep` it is `"Putting to sleep"` — extend the existing `verb` expression rather than restructuring it.

- [ ] **Step 2: Render the new phases**

In `renderMine`, add before the booting/running block:

```js
  if (phase === "building") {
    box.innerHTML =
      `<div class="status"><span class="dot work"></span> Setting up your ${osLabel} desktop for the first time&hellip;</div>` +
      '<div class="sub">This happens once. After this, starting it takes about a minute.</div>' +
      barHtml(isWin ? "windows" : "linux", mine.dispatched_at) + stepsHtml(s.progress);
    tickBars();
    return;
  }

  if (phase === "waking") {
    box.innerHTML =
      `<div class="status"><span class="dot work"></span> Waking your ${osLabel} desktop&hellip;</div>` +
      '<div class="sub">Your files, apps and settings are exactly as you left them.</div>' +
      barHtml(isWin ? "wake_windows" : "wake_linux", mine.dispatched_at) + stepsHtml(s.progress);
    tickBars();
    return;
  }

  if (phase === "sleeping") {
    box.innerHTML =
      `<div class="status"><span class="dot work"></span> Putting your ${osLabel} desktop to sleep&hellip;</div>` +
      '<div class="sub">Everything on it is kept. Starting it again takes about a minute.</div>' +
      barHtml("destroy", mine.sleep_dispatched_at);
    tickBars();
    return;
  }
```

- [ ] **Step 3: Replace Destroy with End session, and add Delete machine**

In the running/booting card, replace the single Destroy row with:

```js
  html += '<div class="row"><button id="sleep" class="stop">End session</button></div>';
  html += '<div class="steps"><div class="sub">Ending a session keeps everything installed. ' +
    '<a href="#" id="delete">Delete this machine</a> to start over from a clean one.</div></div>';
```

and wire them:

```js
  if ($("sleep")) $("sleep").onclick = () => go("sleep");
  if ($("delete")) $("delete").onclick = (e) => { e.preventDefault(); go("delete"); };
```

In `go()`, replace the destroy confirmation with one per action:

```js
  if (action === "delete" && !confirm(
    "Delete this machine?\n\nAnything you installed on it is lost. Your saved files are kept, and a new machine is built next time you start (about 3 minutes)."
  )) return;
  if (action === "sleep" && !confirm(
    "End this session?\n\nEverything stays exactly as it is. Starting again takes about a minute."
  )) return;
```

Keep the existing "Cancel starting" confirmation for a cancel during `building`.

- [ ] **Step 4: The Start card mentions the wake**

In the no-session branch, when the user has machines already (add `has_machines` to `/api/status`'s payload as `Boolean(Object.keys(machines).some(k => k.startsWith(session.user_id + ":")))`), the button's sub-text reads "Ready in about a minute." rather than implying a build.

- [ ] **Step 5: Check every state in the browser**

Serve `panel/public` on port 8799 bound to 0.0.0.0 in the background, override `window.fetch` in the preview browser to return each state in turn, call `poll()`, and confirm:
- `building` → first-time copy, bar sized ~3 min, no credentials.
- `waking` → waking copy, bar ~1-2 min, no credentials.
- `sleeping` → sleep copy, no buttons.
- `running` → Open, End session, and a Delete this machine link.
- no session with machines → Start with "Ready in about a minute."
- no session without machines → Start, first-build copy.
Kill the server by PID (never `pkill -f`).

- [ ] **Step 6: Commit**

```bash
git add panel/public/app.js panel/api/status.js
git commit -m "Page: building, waking and sleeping cards; End session vs Delete machine"
```

---

### Task 8: Prove the whole cycle on real infrastructure

**Files:** none (verification); fixes land in the task they belong to.

- [ ] **Step 1: Local gate**

Run: `cd panel && npm test`, `node --check` on every touched file, YAML parse for all workflows, `terraform fmt -check -recursive terraform`.
Expected: all clean.

- [ ] **Step 2: Build a machine for the throwaway user**

```bash
gh workflow run desktop-up.yml -f username=sddtest -f guest_username=sddtest -f os=linux -f persist=true -f is_guest=false -f use_spot=false
```
Watch it to success. Confirm: the state key in the log is `desktop/user-sddtest/linux/terraform.tfstate`, the instance is on-demand (`InstanceLifecycle` empty, not `spot`), and `https://sddtest.desktop.sihaab.com/healthz` answers 200 (allow ~2 minutes and use a 20s curl timeout — a shorter one fails while the certificate is being issued).

- [ ] **Step 3: Sleep it, and time the sleep**

```bash
time gh workflow run desktop-sleep.yml -f guest_username=sddtest -f os=linux
```
Watch to success. Confirm: the instance reaches `stopped`, `dig +short sddtest.desktop.sihaab.com` returns `192.0.2.1`, and the AWS bill stops (`describe-instances` shows `stopped`).

- [ ] **Step 4: Wake it, and time the wake**

```bash
gh workflow run desktop-wake.yml -f guest_username=sddtest -f os=linux
```
Record wall-clock from dispatch to `/healthz` answering 200. Confirm the DNS record points at the NEW IP and the desktop answers. **This number is the one the progress bar promises** — if it differs from 75s by more than ~30%, update `EXPECTED_S.wake_linux` in `panel/public/app.js` to the measured value, commit, and say so in your report.

- [ ] **Step 5: Confirm files survive a sleep/wake cycle**

Before sleeping (Step 3), write a marker into the desktop over SSH or via the desktop itself; after waking, confirm it is still there. If you cannot reach the desktop's filesystem, state that plainly and verify instead that the root volume ID is unchanged across the cycle (`describe-instances --query 'Reservations[].Instances[].BlockDeviceMappings'`), which is what makes the files survive.

- [ ] **Step 6: Delete the test machine and confirm nothing is left**

```bash
gh workflow run desktop-down.yml -f confirm=DESTROY -f guest_username=sddtest -f os=linux
```
Then:
```bash
aws ec2 describe-instances --region ap-south-1 --filters "Name=tag:Stack,Values=desktop" "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])'
```
Expected: `0`. Also confirm the panel's machine record is gone (`/api/status` shows no machines for sddtest).

- [ ] **Step 7: Report the measured numbers**

Report: measured build, sleep and wake times for Linux; whether `EXPECTED_S` needed changing; anything that behaved differently from the plan. Windows timings are measured after merge, on the owner's own machine, because a Windows build takes ~10 minutes of AWS time.

---

## Notes for the executor

- **The reclaim watcher is now dead weight on these machines.** Every machine this plan builds is on-demand, so AWS never reclaims it. Leave the code alone; it costs nothing and Plan C does not need it removed.
- **Do not add the admin machine list or auto-sleep.** They are Plan C. A machine left running after this plan will run until someone ends the session.
