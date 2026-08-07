# Ephemeral Cloud Desktop — Design

**Date:** 2026-08-07
**Status:** Approved
**Author:** Mohamed Nour

---

## Purpose

An on-demand full Linux desktop, streamed to a browser, running on AWS and defined entirely in Terraform. One command brings it up, one tears it down. Data survives teardown. When it is down, AWS charges effectively nothing.

Two goals, both real:

1. **Utility.** A genuinely useful disposable cloud desktop with working video and audio.
2. **Portfolio.** A DevOps/Cloud artefact demonstrating IaC, remote state, CI/CD, security scanning, cost discipline, and stateless-compute-with-persistent-storage design.

The second goal is served by the first. A project the author actually uses gets finished and can be discussed from experience; a contrived demo cannot.

## Success criteria

- `make up` yields a usable desktop over the tailnet at `https://<host>.<tailnet>.ts.net` within ~3 minutes, on a valid TLS certificate.
- Audio and video play acceptably at 1080p30.
- `make down` leaves **zero billable compute** — no instance, no Elastic IP, no retained EBS volume.
- A file created in the desktop before `make down` is present after the next `make up`. This is the single most important test.
- Desktop data is downloadable to a local machine without the instance running.
- Every Terraform change is gated in CI by format, validate, lint, and security scanning before it can apply.
- No long-lived AWS credentials exist anywhere — CI authenticates via OIDC role assumption.

## Non-goals (explicitly out of scope)

- **GPU acceleration.** Deferred to Phase 2. Software H.264 is sufficient at 1080p30.
- **Kubernetes.** A separate project. Putting k8s here would serve neither goal well.
- **Multi-user access.** Single operator. neko supports more; we do not need it.
- **High availability / 24×7 uptime.** The entire point is that it is off by default.
- **Per-pull-request environments.** Attractive pattern, wrong first project.
- **Persisting the container filesystem.** The environment is reproduced from a Dockerfile, never preserved as a mutated disk. See *Environment reproducibility* below — this is a deliberate inversion of the obvious approach.
- **Version-pinned packages.** Captured by name only. Pinning is more reproducible but breaks rebuilds on upstream updates; for a disposable desktop that trade is not worth it.
- **Non-apt package managers.** snap, flatpak, pip and npm installs are not captured. `pip freeze` diffing could be added later by the same pattern.

## Architecture

```
      ┌──────── PERSISTENT — always exists, costs pennies ───────────┐
      │  S3 bucket: terraform remote state                          │
      │  DynamoDB table: state locking                              │
      │  S3 bucket: desktop data (profile, configs, downloads)      │
      └─────────────────────────────────────────────────────────────┘
                                ▲
                restore on boot │ sync on stop / interruption / manual
                                ▼
      ┌──────── EPHEMERAL — created and destroyed on demand ────────┐
      │  VPC (custom) → public subnet → internet gateway → route    │
      │  Security group: NO inbound from the internet               │
      │  EC2 c7i.xlarge, SPOT, auto-assigned public IP (egress only)│
      │    user-data: Docker → GHCR image → restore data            │
      │               Tailscale → join tailnet + MagicDNS + HTTPS   │
      │               systemd units → save handlers                 │
      │  IAM instance profile: scoped to one S3 prefix only         │
      └─────────────────────────────────────────────────────────────┘
                                │
                  Tailscale MagicDNS + Let's Encrypt cert
                    https://<host>.<tailnet>.ts.net
                    WebRTC media → 100.x.y.z UDP, over the tailnet
```

### Why each choice

**Custom VPC rather than the default.** Costs nothing, and puts subnet/IGW/route-table design into reviewable code.

**No NAT Gateway.** A NAT Gateway is $0.045/hr plus data processing — more than the instance itself. The desktop lives in a public subnet with a public IP and needs no private egress path. Omitting it is the single largest cost decision in this design.

**Auto-assigned public IP, never an Elastic IP.** An EIP bills whether or not it is attached. The author's existing VPN project demonstrates the trap: its EIP costs $3.40/month against $3.26 for the instance. A fresh public IP per boot costs nothing while destroyed. The public address is used for **egress only** — pulling the image and reaching S3 — and is never an ingress path.

**Because the address changes every boot and nothing connects to it inbound, no DNS management is needed at all.** Tailscale MagicDNS gives the instance a stable name automatically. This removes a whole moving part from the original design, along with the need for a Cloudflare API token in CI — one fewer secret to hold is a real security win, not just a simplification.

**TLS via Tailscale, not self-signed or absent.** Tailscale issues genuine Let's Encrypt certificates for MagicDNS names, so the desktop is served over real HTTPS at no cost. This matters beyond neatness: browsers restrict microphone capture to secure contexts, so plain HTTP over the tailnet would silently break audio input even though the WireGuard transport is already encrypted. Free valid certs remove the trade-off entirely.

**Spot instances.** ~$0.10/hr versus ~$0.185 on-demand for `c7i.xlarge` in eu-central-1 (measured, not quoted). Spot's two-minute interruption warning is handled by the *same* save path that a clean shutdown uses, so adopting spot costs almost nothing in extra design. A `use_spot` variable allows falling back to on-demand when spot capacity is unavailable.

**Non-burstable instance family.** `t3.large` is cheaper but burstable: sustained video encoding exhausts CPU credits and the desktop degrades mid-session. Dedicated vCPU is a requirement, not a preference. `c7i.large` (2 vCPU / 4 GB) is too small to run a desktop and encode simultaneously.

**Remote state from the first commit.** CI has no local state file, so S3 + DynamoDB is structurally required rather than aspirational.

**Tailscale for access; security group closed.** WebRTC media travels over UDP and therefore cannot traverse a Cloudflare Tunnel, which is HTTP-only. Rather than expose a full desktop to the internet behind a password, the instance joins the author's existing tailnet and the security group permits no inbound internet traffic at all. Zero internet-facing attack surface.

## Environment reproducibility

The desktop is a **full Linux environment** (`:xfce` — file manager, terminal, arbitrary applications), but its software is defined in code rather than preserved as state. The container filesystem is deliberately disposable; only *user data* persists.

This inverts the obvious design, and the inversion is the point. A desktop whose tooling survives because it was configured by hand is unreproducible — exactly the anti-pattern this project exists to argue against. Instead: installed software is declared in `packages.txt`, consumed by the Dockerfile, and rebuilt from source every time.

To keep that from being annoying in practice, mid-session installs are **captured back into code automatically**:

1. The image bakes a baseline at build time:
   `apt-mark showmanual | sort > /opt/baseline-packages.txt`
2. At save time the session's additions are the diff:
   `apt-mark showmanual | sort | comm -13 /opt/baseline-packages.txt -`
   `apt-mark showmanual` reports only explicitly requested packages, so this captures intent rather than the transitive dependency tree.
3. The diff is written to S3 alongside user data.
4. `make down` / the down workflow appends it to `packages.txt` and **opens a pull request — only if something changed.**
5. Merging the PR rebuilds the image; the next boot has the packages baked in.

**The instance never holds git credentials.** It writes a file to S3; CI raises the PR. That keeps write access to the repository off an internet-facing desktop, makes every environment change reviewable before it becomes permanent, and routes the change through the existing CI gates so image scanning applies automatically.

Workflow in practice: `apt install` what you need to use it now; the Dockerfile catches up on teardown.

## Components

| Path | Responsibility |
|---|---|
| `terraform/bootstrap/` | State bucket, lock table, data bucket. Applied once. Local state, gitignored. |
| `terraform/` | The ephemeral stack: VPC, subnet, IGW, route table, SG, IAM, spot instance. No DNS provider needed. |
| `terraform/user-data.sh.tpl` | Provisions Docker, AWS CLI, Tailscale; pulls the image; restores data; starts neko; installs save handlers. |
| `image/Dockerfile` | Extends `m1k1o/neko:xfce`, installs `packages.txt`, bakes the package baseline. |
| `image/packages.txt` | The declared environment. Single source of truth for installed software. |
| `scripts/save-desktop.sh` | The single save implementation — data sync *and* package capture. One script, three callers. |
| `Makefile` | `up`, `down`, `save`, `status`, `download`, `verify-destroyed`. |
| `.github/workflows/ci.yml` | PR gate: fmt, validate, tflint, Checkov, Gitleaks, Trivy on the image. |
| `.github/workflows/image.yml` | Build and push the desktop image to GHCR on merge to main. |
| `.github/workflows/desktop-up.yml` | `workflow_dispatch` → apply. |
| `.github/workflows/desktop-down.yml` | `workflow_dispatch` → save, destroy, then raise a packages PR if needed. |
| `README.md` | Architecture, measured costs, and an honest log of problems hit. |

GHCR is used rather than ECR: it is free for public images, whereas ECR charges $0.10/GB/month, which would undermine the near-zero idle cost.

Each unit has one job and a defined interface. `save-desktop.sh` in particular is deliberately a single implementation with three triggers, not three near-copies that drift apart.

## Data flow

**Boot:** user-data installs dependencies → `aws s3 sync s3://$DATA_BUCKET/desktop/ /opt/neko-data/` → `docker run` mounting `/opt/neko-data` → Tailscale joins the tailnet → `NEKO_WEBRTC_NAT1TO1` set to the **Tailscale** address.

**Save:** `scripts/save-desktop.sh` does two things — syncs user data (`aws s3 sync /opt/neko-data/ s3://$DATA_BUCKET/desktop/ --delete`) and writes the captured package diff to `s3://$DATA_BUCKET/desktop/new-packages.txt`. Triggered by:
1. systemd unit `ExecStop` — clean shutdown and `terraform destroy`
2. A watcher polling IMDS `/latest/meta-data/spot/instruction` — spot reclamation
3. `make save` — manual, mid-session

**Package feedback loop:** after destroy, CI reads `new-packages.txt`, appends any entries to `image/packages.txt`, and opens a pull request if the file changed. Merging rebuilds the image. No git credentials exist on the instance.

**Download:** `make download` runs `aws s3 sync` from the data bucket to a local directory. Works whether or not the instance exists, satisfying the requirement that data never be trapped.

## Configuration

Ports, per upstream neko documentation:

- TCP 8080 — web UI, fronted by Tailscale HTTPS; reachable over the tailnet only
- UDP 52000–52100 — WebRTC media, mapped **1:1 with no remapping**, which upstream requires
- `NEKO_WEBRTC_EPR=52000-52100`
- `NEKO_WEBRTC_NAT1TO1` — set to the **Tailscale** address (`100.x.y.z`), *not* the public IP. Setting the public IP here is the most likely first failure: the UI loads and media never connects, because ICE advertises an address the client cannot reach.

Security group: **no inbound rules whatsoever.** Both the UI and media arrive through the Tailscale interface, which needs no open ports — WireGuard establishes its path outbound.

## Error handling

| Failure | Behaviour |
|---|---|
| Spot capacity unavailable | `apply` fails clearly. Retry with `use_spot=false` for on-demand. |
| Spot interruption mid-session | IMDS watcher fires the save script inside the two-minute window. |
| First-ever boot, no data in S3 | Initialise a fresh profile. Distinguished from a *failed* restore — an empty bucket is normal, an errored sync is not, and the two must not be conflated. |
| Restore errors (permissions, network) | Fail loudly and do not start neko. Silently starting with an empty profile risks the next save overwriting good data with nothing. |
| Tailscale auth key expired | Instance boots but is unreachable. Use a reusable, non-expiring-within-90-days key; document rotation. |
| `NEKO_WEBRTC_NAT1TO1` wrong | UI loads, media never connects. Documented as the most likely first failure. |
| `make down` with unsaved work | `down` always runs save before destroy. Never destroy without saving. |
| Package capture produces no diff | Normal. The PR step is skipped entirely rather than opening an empty pull request. |
| Package installed then removed in the same session | Diff is computed at save time, so it correctly reports nothing. |
| A captured package no longer exists upstream | The image build fails on the packages PR, before it can reach `main`. The CI gate is the safety net. |
| GHCR image pull fails at boot | Fail loudly; do not fall back to the upstream base image, which would silently give a desktop missing every declared tool. |

## Testing

**Automated (CI, every PR):** `terraform fmt -check`, `terraform validate`, `tflint`, `Checkov`, `Gitleaks`, plus `Trivy` against the built desktop image. The image must build successfully, which is what catches a bad captured package. No apply on PRs.

**Acceptance (manual, the tests that matter):**
1. **Persistence round-trip** — `up` → create a known file on the desktop → `down` → `up` → file is present. The defining test of the whole design.
2. **Media** — 1080p video plays with audible, in-sync audio.
3. **Cost teardown** — `make verify-destroyed` enumerates instances, Elastic IPs, and volumes across the region and asserts nothing billable remains.
4. **Spot interruption** — simulate via the EC2 spot interruption API and confirm data is saved.
5. **Isolation** — from a device *not* on the tailnet, confirm the desktop is completely unreachable.
6. **Package round-trip** — `up` → `apt install` a package → `down` → confirm a PR is raised containing exactly that package → merge → `up` → the package is present with no manual install. This proves the reproducibility claim rather than asserting it.

## Cost model

Measured spot pricing, eu-central-1, 2026-08-07:

| State | Cost |
|---|---|
| Running, `c7i.xlarge` spot | ~$0.10/hr |
| 2 hr/day × 20 days | ~$4.03/month |
| Destroyed | ~$0.12/month (S3 storage only) |

Compare a NAT Gateway ($32/mo) or an Elastic IP ($3.65/mo idle), both deliberately avoided.

## Security posture

- Security group has **no** inbound internet rules. Access is tailnet-only.
- IAM instance profile is scoped to a single S3 bucket prefix — not `s3:*`.
- CI authenticates to AWS by **OIDC role assumption**; no long-lived access keys exist. This directly addresses a prior incident where a manually copied IAM secret key was silently truncated.
- The Tailscale auth key is the **only** secret required, held in GitHub Actions secrets and never in the repository. Removing DNS management eliminated the Cloudflare token entirely.
- Gitleaks runs on every PR.
- Terraform state contains sensitive values, which is why the state bucket is private, encrypted, and versioned.

## Phases

**Phase 1 (this spec).** neko `:xfce` full desktop from a custom GHCR image, CPU encoding, spot, Tailscale access, S3 data persistence, package capture feeding pull requests, CI gates, OIDC.

**Phase 2 — GPU.** Swap to `g4dn.xlarge` (~$0.30/hr spot) with NVIDIA drivers for hardware encoding, or move to Selkies-GStreamer. Everything else unchanged, which is the point: the encoder is a swappable layer.

**Phase 3 — optional.** Scheduled auto-destroy as a safety net against forgetting; a second workload; a Kubernetes variant.

## Open questions

None. Access model resolved (Tailscale), instance type resolved (`c7i.xlarge` spot), workload resolved (neko `:xfce`), persistence resolved (S3 sync).
