# Ephemeral Cloud Desktop

A full Linux desktop (KDE Plasma, GPU-capable, audio and clipboard included)
that boots on AWS in minutes, streams to any browser, and costs **~$1.90/month
when nobody's using it.** One click to start, one click to destroy — your
files, apps, and settings survive every teardown.

**Live:** [desktop.mnour.dev](https://desktop.mnour.dev) — self-service panel with Google sign-in
**Admin console:** `admin.desktop.mnour.dev` — tiers, guest limits, live session state

---

## Why this exists

Cloud desktops are usually priced for people who leave them running. This one
is priced for people who don't. The interesting engineering was never "run a
desktop in AWS" — it's making compute genuinely *disposable* (destroyed
completely between sessions, zero idle cost) while everything that matters
(files, credentials, installed software) survives that destruction anyway.
Getting that split right, and keeping it right as the project grew from a
single manually-started box into a multi-tier self-service product, is what
this repo actually documents.

## Architecture

```
                          ┌─────────────────────────┐
   Browser ───HTTPS──────▶│  Vercel (serverless)     │
                          │  desktop.mnour.dev       │
                          │  admin.desktop.mnour.dev │
                          │  Google Sign-In auth     │
                          └────────────┬─────────────┘
                                       │ workflow_dispatch
                                       │ (GitHub Actions API)
                          ┌────────────▼─────────────┐
                          │   Upstash Redis           │
                          │   sessions · tiers ·      │
                          │   config · history         │
                          └────────────┬─────────────┘
                                       │
                          ┌────────────▼─────────────┐
                          │   GitHub Actions          │
                          │   START · DOWN · WIPE ·   │
                          │   REAPER · BAKE-AMI       │
                          └────────────┬─────────────┘
                                       │ terraform apply
                          ┌────────────▼─────────────┐
                          │   AWS ap-south-1 (Mumbai) │
                          │   spot c7i.xlarge          │
                          │   (or g4dn.xlarge + GPU)  │
                          │   Caddy → webtop → KDE     │
                          │   Selkies WebRTC streaming │
                          └───────────────────────────┘

   PERSISTENT (never destroyed)          EPHEMERAL (destroyed every session)
   ───────────────────────────           ───────────────────────────────────
   S3        terraform state             VPC, subnet, security group
   EBS 20GB  /config, desktop home       EC2 instance (spot or on-demand)
   random_password  credentials          Caddy TLS termination
                                          Cloudflare A record — updated in
                                          place, never deleted
```

The panel never touches AWS directly — every action is a `workflow_dispatch`
call, so GitHub Actions is the *only* thing with AWS credentials, and every
provisioning action is versioned, logged, and reviewable in the Actions tab.

### Four independent Terraform stacks, on purpose

| Stack | Contains | Lifecycle |
|---|---|---|
| `terraform/bootstrap/` | S3 state backend | apply once, ever |
| `terraform/persistent/` | 20GB EBS volume, desktop credentials | **never destroyed** |
| `terraform/network/` | Shared VPC, subnet, security group | applied once, shared by all sessions |
| `terraform/` | Per-session instance, per-session SG rules, DNS | destroyed every session |

`prevent_destroy` on the volume, inside the desktop stack, would make
`terraform destroy` *fail* rather than skip it — which defeats "one command
down." Splitting the volume into its own stack is what makes teardown
actually safe to run unattended, from a cron job, on every session.

## DevOps techniques in play

- **Infrastructure as Code**, split into 4 stacks by *lifecycle*, not by
  service — the organizing question is "does this outlive the machine?", not
  "is this networking or compute?"
- **GitHub Actions as the control plane.** `workflow_dispatch` inputs are the
  entire interface between the web panel and AWS; nothing else holds AWS
  credentials. Every workflow has `concurrency` groups (per-username, so two
  guests never queue behind each other), `timeout-minutes` (bounded so a
  wedged apply can't hold a lock for GitHub's 6-hour default), and
  `-lock-timeout` on every Terraform call (a lock contention is a
  wait-your-turn situation, not a failure).
- **S3 native state locking** (`use_lockfile`) instead of a DynamoDB lock
  table — fewer resources to create, secure, and bill, and the DynamoDB
  pattern is deprecated in current Terraform.
- **Serverless control plane** (Vercel + Upstash Redis) fronting a
  **fixed-cost compute plane** (AWS) — the always-on part of this project
  (the website) runs for effectively nothing, and the part that costs real
  money (a GPU-capable desktop) exists only while someone is using it.
- **A real tiered-access model**, not a toggle: admins, permanent users, and
  guests, backed by Redis, enforced server-side (never trusted from the
  client) at the one place that actually dispatches AWS work.
- **A scheduled reaper**, not an honor system. Guest desktops carry a
  `Role=guest-desktop` AWS tag (no hardcoded username list — discovery is by
  tag) and get destroyed by a cron-triggered workflow the moment they exceed
  an admin-configurable time limit, based on the EC2 API's own `LaunchTime`
  rather than an in-guest activity tracker that could silently go stale.
- **An AMI baking pipeline** (`bake-ami.yml`) that pre-installs everything
  user-data would otherwise fetch on every boot — apt packages, the Caddy
  binary with its DNS plugin, and (opt-in) the NVIDIA driver stack — cutting
  boot-to-ready time and, more importantly, removing *variable* boot time
  caused by fetching things over the network on every single start.
- **Opt-in GPU support** (NVENC hardware encoding via `-e gpu=true`) that
  **hard-fails** rather than silently falling back to software encoding if
  the GPU isn't actually usable at boot — a silent fallback would bill 3.2x
  more for zero benefit and nobody would ever notice.
- **Cost decisions backed by measurement, not assumption**: spot vs
  on-demand, region choice, availability-zone choice, and instance family
  were all decided from real measured numbers (see below), including
  reversing a decision after the numbers came back wrong.
- **Security modeled as least-privilege by session**: no NAT Gateway (a
  public subnet is cheaper for outbound-only egress), no Elastic IP (bills
  whether attached or not, and the address changes every session anyway),
  DNS updated in place rather than deleted (deleting it caused ~30 minutes of
  cached NXDOMAIN on the *next* session), and no secrets ever routed through
  a `workflow_dispatch` input on a public repository (GitHub echoes
  `inputs.*` into job logs unmasked — only `secrets.*` is protected).

## Real bugs, found and fixed

Not a changelog — the actual failure, the actual root cause, and how it was
caught. Nearly all of these were **silent**: something reported success while
doing the wrong thing, which is the failure mode that actually costs time.

**Reaper destroying the wrong desktops.** The scheduled reaper discovered
"every live desktop" and killed anything past the guest time limit — with no
way to tell a guest's desktop from the owner's own persistent one. Fixed by
tagging every instance `Role=guest-desktop` vs `user-desktop` at creation
time, threaded end-to-end from the panel's dispatch call through to the
Terraform tag, and verified with a real `terraform plan` diff on both
branches before merging.

**A public API endpoint returning 422 on every guest launch.** The panel
(deployed instantly via Vercel) started sending an `is_guest` input the
`desktop-up.yml` workflow on `main` didn't declare yet — because GitHub Actions
always reads workflow *files* from the ref being run, and the feature branch
containing that input hadn't been merged. The panel and the infra it drives
can silently drift out of sync the moment one deploys faster than the other.

**The admin console served the guest panel instead.** `admin.desktop.mnour.dev`
was rewritten to `/admin.html` at the same path (`/`) as the main panel — and
Vercel's CDN cache key is **path-only, not `Host`-varying**, so the two
domains collided and one served the other's cached response
(confirmed via `X-Vercel-Cache: HIT`). Fixed by redirecting to a distinct
path instead of rewriting to a shared one.

**The panel looked frozen on "Starting…" for the entire multi-minute boot.**
Clearing the "Starting…" spinner and firing the one-time
auto-open-a-new-tab were both gated on the *exact same* condition
(`status === "active"`, i.e. a full health check pass) — so the page sat on a
bare spinner through the whole boot even though the real booting-with-credentials
card was available the entire time, and only a manual refresh (which reset
the in-memory flag) ever revealed it. Fixed by splitting "clear the spinner"
from "auto-open the tab" into two independent conditions. A related bug in
the same code path — mobile browsers throttle or freeze `setInterval` in a
backgrounded tab, so returning to the tab never re-polled — was fixed with
explicit `visibilitychange`/`focus` listeners.

**The owner's own persistent desktop was unrecoverable — twice, from the same
root cause.** The EBS volume holding `/config` lives in its own
never-destroyed Terraform stack, keyed to a `region`/`az_suffix` pair that
has to match the desktop stack exactly. It drifted out of sync **twice**:
once when the desktop moved from Frankfurt to Mumbai and the persistent
stack's defaults weren't updated, and again when an aborted UAE migration
attempt got reverted everywhere *except* this one file. Both times the
failure mode was the same: a `terraform apply` on the desktop stack failing
with "your query returned no results" on the volume lookup, because the
volume terraform *thought* existed had actually been deleted out from under
a stale region pointer. Fixed both times by correcting the region/AZ
defaults and re-applying to create a fresh volume in the right place — safe
specifically *because* the old volume no longer existed to lose.

**A GPU AMI bake that made boot slower, not faster.** The bake workflow
hardcoded the container image tag (`ubuntu-kde`) while the desktop's actual
default had moved to `debian-kde` — so the AMI baked in the wrong image's
layers while the boot still had to pull the real one, adding disk-hydration
time for zero benefit (383s vs. a 325s baseline). Fixed by extracting the
image tag from `terraform/variables.tf` at bake time instead of hardcoding
it — and while investigating, found the *actual* bottleneck wasn't the image
pull at all: it was Caddy making a live build request to `caddyserver.com`
for a DNS plugin, on every single boot. Fixed by baking the Caddy binary
itself into the AMI, with a `caddy list-modules` check before trusting it.

**A cloud provider quota check that lied — twice.**
`aws ec2 run-instances --dry-run` reported "Request would have succeeded" for
a GPU instance type while the account's actual GPU vCPU quota was still `0`.
The real launch failed both times with `VcpuLimitExceeded` — once for a live
test, once inside the bake workflow. `--dry-run` validates IAM permissions,
not service quotas. Fixed by trusting only the real
`aws service-quotas get-service-quota` value going forward, never the
dry-run signal.

**A region decision reversed after the numbers came back wrong.** UAE
(`me-central-1`) looked like the obvious latency win over Mumbai — until
`RunInstances` returned throttling errors for every instance type tested, and
research turned up a real physical incident (a drone-strike/fire) that had
degraded that region's capacity for months. A full network stack had already
been applied there before the numbers ruled it out; rather than migrate
blind, every active pointer (workflows, Terraform defaults, panel pricing
constant) was reverted back to Mumbai, and the UAE stack left dormant rather
than torn down mid-decision.

**A security group description with an apostrophe.** `"when it's on"` was
silently rejected by `CreateSecurityGroup`'s allowed character set — but only
at real `apply` time, never at `validate` or `plan`. Fixed, then every SG
description across all three stacks was audited for the same class of bug.

**A stale provider lockfile, rewritten on every local `terraform init`.**
Developing on ARM64 while CI runs AMD64 meant `.terraform.lock.hcl` churned
on every local init. Fixed with `terraform providers lock -platform=linux_amd64
-platform=linux_arm64` across all three stacks, so the lockfile is valid on
both without either side fighting the other.

**Callback secret mismatch.** `HUB_CALLBACK_SECRET` differed between the
GitHub secret and the Vercel env var by (almost certainly) trailing
whitespace picked up during initial setup — surfacing as a flat `403 bad
callback secret` on every session-ready callback, fixed by regenerating and
resetting both sides explicitly rather than guessing which one was wrong.

## Cost

| State | Measured |
|---|---|
| Running, `c7i.xlarge` spot, `ap-south-1c` | **$0.0529/hr** |
| Running, `g4dn.xlarge` spot + GPU (opt-in) | ~3.2x the CPU rate |
| 2 hr/day × 20 days | ~$2.12/month |
| Fully destroyed | **~$1.90/month** — the 20GB volume, nothing else |

That $1.90 is the price of "destroy the machine, keep the work." It's a
deliberate trade, not overhead — and it's the number that makes "disposable
compute" actually disposable instead of just cheap.

## Known gaps

Stated plainly rather than omitted.

- **GitHub Actions uses static AWS keys.** OIDC is the intended design; the
  scoped IAM policy is written and ready at `docs/aws-permissions-policy.json`,
  waiting on an account admin to attach it.
- **No SSM agent on the instance.** Same missing permission as above — there
  is currently no remote shell into a running desktop for diagnostics beyond
  what CloudWatch metrics and the application's own health endpoint expose.
- **Package installs are not declarative.** They persist on the volume,
  which is the intended behavior, but nothing records *what* was installed
  in a form that's reviewable in a diff.
- **GPU quota approval is outside this project's control.** The `bake-ami`
  and desktop-start GPU paths are fully built and tested for correctness, but
  actually exercising them end-to-end is gated on an AWS service-quota
  increase sitting in a manual review queue.

## Repository layout

```
terraform/                per-session desktop stack (instance, SG, DNS)
terraform/persistent/     EBS volume + credentials — never destroyed
terraform/network/        shared VPC/subnet/SG — applied once
terraform/bootstrap/      S3 state backend — applied once, ever
panel/                    Vercel serverless panel
  api/                    session dispatch, status, admin endpoints
  api/admin/              tier management, config, live state (admin-only)
  lib/                    Redis-backed session/tier state, GitHub dispatch, auth
  public/                 the panel and admin console front ends
.github/workflows/
  desktop-up.yml            start a session (owner or guest, CPU or GPU)
  desktop-down.yml          destroy a session, keeping data if asked
  desktop-wipe.yml          permanently delete saved data
  desktop-reaper.yml        cron-scheduled guest time-limit enforcement
  bake-ami.yml               pre-bake a CPU or GPU AMI
scripts/set-dns.sh        in-place Cloudflare DNS update (never deletes)
docs/                     design specs, implementation plans, IAM policy
```
