# Sleeping machines: no waiting for a desktop to be created

Date: 2026-09-17
Status: approved design, not yet implemented

## Goal

A user should not wait ~3 minutes for a machine to be built. After this
change they wait ~1 minute for their own machine to wake, and that machine
comes back with their apps, settings and files exactly as they left them.

The cheap way to do that is not to keep machines running. A **stopped** EC2
instance keeps its root disk and costs only storage (~$4/month for a 50GB
Windows disk, ~$2.50 for 30GB Linux), and starting one takes ~40-60s instead
of a full build.

## Decisions

| Decision | Why | Rejected |
|---|---|---|
| One machine per user, parked when unused | Cost scales with real users, and waking their own machine keeps installed apps - no claiming, no re-attaching | A shared warm pool: a claimed spare still has to take the user's hostname and drive, so it is slower AND more moving parts |
| Stopped, not idling | ~$4/month vs ~$260/month per always-on Windows machine | Keeping one Windows + one Linux always on: ~$390/month for two machines |
| One machine per user, not one per OS | Parking both OSes doubles the standing cost. Switching OS deletes the parked machine after a confirmation; the saved drive per OS survives | Allow both (small change, more disk) - revisit if switching turns out to be common |
| Wake via a slim GitHub Actions workflow | The panel holds no AWS credentials by design; a compromised panel must not be able to touch infrastructure | Panel calls AWS directly (~20s faster, breaks that property); a Lambda the panel calls (~20s faster, new infrastructure). Lambda stays the contained upgrade if wake time annoys in practice |
| Build on sign-in, then park | First start becomes a wake for everyone. A build is ~3 min of compute (a couple of cents); a parked machine is disk only | Build when the admin adds the user (pays disk for people who never sign in); build lazily (first start stays slow) |
| Auto-sleep on idle, default 30 min | One forgotten Windows session is ~$8.70/day, more than a year of that machine's parked cost | Manual only |
| No automatic deletion of parked machines | Owner's decision; deleting a machine throws away installed apps | Idle-days reaper, max-count cap |
| Guests removed entirely | Only permanent users get access for now | - |

Parked machines must be **on-demand**: a spot instance cannot be stopped and
resumed, only terminated. A running Linux session therefore costs $0.1785/hr
instead of ~$0.073 spot. Auto-sleep is what keeps that from mattering.

## Machine states

A **machine** outlives a session. One per user.

```
none ──build──> sleeping ──wake──> running ──sleep──> sleeping
                    │                  │
                    └──── delete ──────┴──> none
```

- **none** - nothing built. Sign-in triggers a build.
- **sleeping** - EC2 stopped. Hostname parked on 192.0.2.1 (existing
  set-dns.sh behaviour, so the name never points at a stranger's machine).
  Costs disk only.
- **running** - in use, billing hourly.

Terraform state is kept for a sleeping machine. Sleep and wake are plain EC2
stop/start calls and never run Terraform; only **delete** runs
`terraform destroy`.

### Data

New Redis hash `machines`: username -> `{instance_id, os, state, region,
hostname, created_at, last_woken_at, root_gb}`. The existing `sessions` hash
keeps its meaning (a live session), so the panel can distinguish "has a
machine" from "is using it".

New phases, rendered by the page the same honest way as today's start:
`building` (first time, ~3 min) and `waking` (~1 min). "Sleeping" is a state
of the MACHINE, not of a session: there is no session then, and the card
shows the Start button with "ready in about a minute".

## Flows

**Sign-in build.** A permanent user signs in with no machine: the panel
dispatches the build, guarded by a one-shot claim so a refresh or a second
tab cannot start two. The card says "Setting up your desktop for the first
time - about 3 minutes". When the build finishes, the machine parks itself UNLESS the user clicked
Start while it was building - in which case it stays running and goes
straight to the running card, so nobody waits twice.

**Start = wake.** The panel dispatches `desktop-wake.yml`: start the
instance, wait for it to boot, repoint DNS to the new public IP
(scripts/set-dns.sh), post session-ready. Card shows "Waking your desktop..."
with a bar sized to ~1 minute. Measured expectation: ~60-75s Linux,
~90-120s Windows.

**End session = sleep.** `desktop-sleep.yml`: stop the instance, park the
hostname, post session-ended. The machine record stays, marked sleeping.

**Auto-sleep.** Each machine watches its own streaming connections and, after
the admin-set idle timeout with nobody connected, POSTs `/api/session-idle`
with its per-session token (the mechanism added in PR #32 for spot reclaims -
no new credential on the machine). The panel dispatches the sleep.
 - Windows: DCV session connection count (`dcv describe-session`).
 - Linux: live connections to the desktop port; /healthz probes excluded.
 - An open tab counts as connected, so reading without typing is not idle.
 - Backstop: the panel also tracks how long a session has had no successful
   probe and parks it, in case the on-machine watcher dies.

**Delete.** From the user's card ("Delete machine", warning that installed
apps go with it) or the admin console. Runs today's `desktop-down.yml`
(terraform destroy) and drops the machine record. Saved drives are never
touched.

**OS switch.** Choosing the other OS when a parked machine exists asks for
confirmation, deletes it, and builds the other (~3 min). The saved drive for
each OS is kept, as today.

## Guests removed

- No guest sessions, no guest time limit, no "keep my files" checkbox
  (permanent users always keep files).
- A signed-in account that is neither admin nor permanent user sees a plain
  "access isn't enabled - contact the owner" message. Nothing is built or
  billed.
- `desktop-reaper.yml` loses time-limit destruction and becomes the backstop
  pass: park anything running with no session.
- Admin console: the guest-limit setting is replaced by the idle timeout, and
  a machines list (user, OS, state, cost) gains a Delete on each row.
- Existing guest data volumes are left alone. Deleting anyone's files stays
  the owner's decision.

## Cost

| | |
|---|---|
| Sleeping Windows machine | ~$4/month (50GB gp3) |
| Sleeping Linux machine | ~$2.50/month (30GB gp3) |
| Running Windows | $0.3625/hr (c7i.xlarge on-demand, ap-south-1) |
| Running Linux | $0.1785/hr on-demand |
| Five permanent users, parked | ~$20/month standing |

## Failure modes

| Failure | Behaviour |
|---|---|
| Wake fails: no capacity for that type/zone | Card says the machine could not be woken, offers a rebuild (~3 min). Nothing deleted; a later retry may work |
| Instance gone (AWS retirement, deleted outside the panel) | Wake detects it and falls back to building |
| Sleep fails | Machine keeps running and still shows as running - visible and actionable. Backstop pass catches it |
| Stop during a file write | A stop is a normal ACPI shutdown; both OSes flush and close cleanly |
| Two builds from a refresh/second tab | One-shot claim (SET NX EX), as used by session-lost |
| Idle watcher dies | Panel-side no-probe backstop parks the machine |
| Wake races a sleep | Per-user concurrency group already serialises lifecycle workflows |

## Testing

- Unit tests for the new pure rules: legal state transitions, idle
  arithmetic, which phase the card renders, cost per state.
- `bash -n` and YAML parse for the new workflows; rendered user-data checked
  as in PR #32.
- End-to-end on a **throwaway test username, never a real user's account**:
  build -> park -> wake -> confirm installed apps and files survive -> idle
  auto-sleep with a short timeout -> delete.
- Wake timings recorded for both OSes and compared against the ~1 min claim
  on the card; the progress bar is sized from the measurement, not a guess.

## Out of scope

- Deleting parked machines automatically (owner's decision).
- A shared warm pool for bursts of new users.
- Hibernation (RAM preserved) - a bigger root disk and more constraints for
  a few seconds of wake time.
- GPU sessions.
