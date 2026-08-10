# Finish the AWS ephemeral cloud desktop

**Date:** 2026-08-10
**Scope:** the AWS desktop only. The Pi-hosted desktop is a separate future brainstorm.

## Why this spec exists

Every piece of this system is roughly 90% done and almost nothing is 100% done.
The guest self-service flow — Google sign-in, per-user hostnames, persistence
choice, audit history, concurrency cap — is fully built and **has never once
successfully started a desktop**. "Finished" had never been defined, so the work
had no edge. This document defines it.

## Definition of done

Eight criteria. Each is testable by observation, not opinion.

1. A **non-admin** Google account signs in at `desktop.mnour.dev`, clicks Start,
   and reaches a working desktop at `<username>.desktop.mnour.dev`.
   (`n4mu0r@gmail.com` is already registered as a non-admin user, so this is
   testable without creating a new account.)
2. With *keep my data* on: a marker file and an `apt`-installed package **survive
   destroy → restart**, reusing the same EBS volume.
3. With *keep my data* off: **no volume is ever created** — verified by its
   absence in the AWS API, not assumed from the absence of an error.
4. A user can destroy **their own** desktop and **cannot** destroy anyone else's.
5. The **admin** (`mnuowr@gmail.com`) sees all sessions and history and can
   destroy any desktop.

   *(The original requirement also said the admin's desktop must never be
   auto-destroyed. That is moot while D2 holds — nothing is auto-destroyed at
   all. It becomes a real requirement again the moment any reaper is
   re-enabled, and the mechanism then is an `IdleExempt` / owner-aware tag the
   reaper skips, not a username hardcoded into the workflow.)*
6. Concurrency capped at 5. A 6th user sees "try again shortly" with no number
   disclosed.
7. Every login / start / destroy is recorded in history, with duration on destroy.
8. A stranger holding the URL **cannot reach a desktop** without authenticating.

### Deliberately dropped

**Idle-based auto-destroy is out**, at the owner's request, and the *mechanism*
is being disabled rather than merely left untested — see Decisions.

## Decisions

### D1. Prove before securing (approach A)

Order: place the token → prove one real end-to-end cycle → then Cloudflare
Access → then monitoring.

Rationale: this project produced six real bugs in a single evening (session
cookie path, CPU architecture mismatch on the Caddy build, a missing DNS A
record, token loss on instance replacement, `basic_auth` swallowing
machine-to-machine callbacks, and un-rolled-back pending state). **Every one was
found by isolating a variable and measuring it; not one was found by reading
code.** Stacking a proxy layer, WebSocket pass-through and an identity policy on
top of a base case that has never succeeded would turn one suspect into four.

### D2. Disable the reaper's schedule, do not merely skip its test

The idle reaper polls `/last-activity` on each desktop, served from a file kept
current by an `activity-tracker` service that tails Caddy's access log. That
tracker has never been verified against real traffic. It has two failure modes,
and they are **not** equally safe:

| Failure | Effect | Safe? |
|---|---|---|
| Log-line pattern doesn't match | Monitoring traffic counts as activity → never destroys | Yes |
| **Tracker service dead** | Timestamp frozen at boot → **destroys a desktop in active use after 4h** | **No** |

The second is real: the file is written once at boot, so it keeps returning a
valid-looking number even if the tracker never runs again. An unverified
auto-destroyer on a 15-minute cron, with its verification declared out of scope,
is the worst of both options. The `schedule:` trigger is removed;
`workflow_dispatch` stays so the code remains exercisable.

**Accepted consequence:** nothing now prevents a forgotten desktop billing at
$0.104/hr. For a single operator this is visible (the panel shows running time
and session cost) and manually fixable. **This gap must be closed before real
guests use the system.** The recommended mechanism then is a *max-session-age*
reaper reading `LaunchTime` from the EC2 API — it depends on nothing running
inside the instance and therefore has no unverifiable moving parts.

### D3. Cloudflare Access, one application per desktop

Terraform creates a `cloudflare_access_application` plus policy per desktop,
scoped to that desktop's hostname, with the policy `email == var.owner_email`.
Created and destroyed with the desktop. Each desktop therefore opens only for
the account that started it, enforced at Cloudflare's edge before the request
reaches AWS.

Requires flipping the desktop DNS records from DNS-only to **proxied** — Access
cannot apply to an unproxied hostname. `/healthz` gets a bypass policy so
monitoring keeps working. webtop's own basic auth stays underneath as defence in
depth.

**Must be tested, not assumed:** Selkies streams over a single TCP connection
using WebSockets. Cloudflare's proxy supports WebSockets, but this specific
path has never been exercised. If it fails, the fallback is Access on the
control plane only, with desktops reachable over Tailscale.

## Phases

### Phase 1 — Prove the guest flow (blocked on: GitHub PAT)

1. Write the PAT to `/mnt/hubdata/control/github-token` (persistent volume, so
   it survives instance replacement — it has already been lost twice this way).
2. Delete the stale `desk-a` / `desk-b` DNS records left from the abandoned
   2-slot design.
3. Remove the reaper's `schedule:` trigger (D2).
4. One real cycle, `persist = on`:
   - start → verify instance tags (`Owner`, `Role=guest-desktop`), volume
     created and tagged, DNS record live, certificate issued, `/healthz` 200,
     and the panel showing URL + password
   - log in to the desktop, create a marker file, `apt install` a package
   - destroy → verify instance gone, **volume retained**, DNS parked at
     `192.0.2.1`, session back to idle, history shows a duration
   - start again → marker file and package still present, same volume id
5. Second cycle, `persist = off`: verify **no volume is created at all**.
6. Verify a second (non-admin) account cannot destroy the first one's desktop.

### Phase 2 — Cloudflare Access (criterion 8)

Flip desktop DNS to proxied; add the per-desktop Access application and policy
in Terraform; bypass `/healthz`; test WebSocket pass-through end to end with a
real session; confirm an unauthenticated request is refused at the edge.

### Phase 3 — Monitoring that actually monitors

Uptime Kuma currently has **zero monitors** — the box exists because a 17-day Pi
outage went unnoticed, and it presently watches nothing. Add monitors for
`mnour.dev`, `whasal.com`, `hub.mnour.dev`, `desktop.mnour.dev` and the VPN,
wired to the existing ntfy topic. **Verify by causing a real failure and
confirming the alert reaches the phone** rather than trusting that it would.

## Out of scope

- The Pi-hosted desktop (separate brainstorm; Pi 5 has no hardware H.264
  encoder, so it trades better latency for worse rendering)
- Kubernetes / k3s (belongs on the home lab, not bolted onto a single-instance
  ephemeral desktop where it would be architecture theatre)
- Home-lab monitoring, Healthchecks.io, Tailscale key for the hub

### Blocked on the account admin, not on us

- GitHub OIDC and removing the static AWS keys — needs `iam:CreateRole`
  (policy ready at `docs/aws-permissions-policy.json`)
- AWS console password reset
- IAM billing access, and therefore the remaining credit balance

## Known risks

| Risk | Handling |
|---|---|
| Selkies WebSockets through Cloudflare's proxy untested | Test in Phase 2; fall back to Tailscale-only desktops |
| Activity tracker unverified | Mechanism disabled (D2), not relied upon |
| Forgotten desktop bills indefinitely | Accepted for single-operator use; must close before guests (D2) |
| Config lost on instance replacement | Everything hand-set now lives on the persistent volume |
