# Ephemeral Cloud Desktop

A full Linux desktop, streamed to the browser over WebRTC, provisioned on AWS
entirely with Terraform. One command up, one command down. Your data survives
teardown. When it is down, AWS bills effectively nothing.

## Why this exists

I wanted a disposable cloud desktop I could actually use — with working audio
and video — without paying for an idle instance. The interesting engineering is
not the desktop; it is making compute genuinely disposable while keeping state.

## How it works

    PERSISTENT (pennies/month)          EPHEMERAL (created and destroyed)
    S3: terraform state                 VPC → public subnet → IGW
    S3: desktop data                    Security group: zero inbound rules
    IAM: GitHub OIDC + CI role          EC2 c7i.xlarge SPOT
                                          Docker → neko:xfce
              ▲                             Tailscale → tailnet + HTTPS
              └──── restore / save ────────  systemd → save handlers

Access is over Tailscale only. The security group has **no inbound rules at
all** — not a locked-down range, none. The desktop is reachable from devices on
my tailnet and from nowhere else.

## Design decisions worth defending

**No NAT Gateway.** A NAT Gateway costs $0.045/hr plus data processing — more
than the instance it would serve. A public subnet with a public IP used for
egress only does the job.

**No Elastic IP.** An EIP bills whether attached or not. In an earlier project
of mine the EIP cost more per month ($3.40) than the instance it served
($3.26). Here the public address is ephemeral, and nothing needs to reach it
inbound, so there is nothing to reserve.

**No DNS management.** Because the address changes each boot and nothing
connects inbound, Tailscale MagicDNS provides a stable name for free. That
removed an entire moving part and one credential.

**Spot instances.** ~$0.0878/hr against ~$0.185 on-demand. Spot's two-minute
interruption warning triggers the same save path a clean shutdown uses, so
adopting spot cost almost no extra design.

**Non-burstable instance family.** `t3` is cheaper but burstable: sustained
video encoding exhausts CPU credits and the desktop degrades exactly when in
use. Dedicated vCPU is a requirement, not a preference.

**Region `me-central-1`.** I am in Abu Dhabi. ~5–15ms to the UAE region against
~110–130ms to Frankfurt, and measured spot pricing is 16% cheaper. Region
follows the workload.

**S3 native state locking.** `use_lockfile` on the S3 backend rather than a
DynamoDB lock table. DynamoDB-based locking is the deprecated pattern in
current Terraform — this is one fewer resource to create, secure, and bill.

**No static AWS credentials.** GitHub Actions assumes an IAM role via OIDC with
a token minted per run. There is no access key to leak or rotate. This is a
direct response to an earlier project where a hand-pasted IAM secret key was
silently truncated by drag-selecting it.

**The environment is rebuilt, not preserved.** Installed software lives in
`packages.txt` and is reinstalled from the Dockerfile every boot. Mid-session
`apt install`s are captured and raised as a pull request against that file, so
the machine never holds git credentials and every environment change is
reviewable.

## Cost

| State | Cost |
|---|---|
| Running (`c7i.xlarge` spot, me-central-1) | ~$0.0878/hr |
| 2 hr/day × 20 days | ~$3.51/month |
| Destroyed | ~$0.12/month (S3 storage only) |

## Status

Plan 1 (foundation) in progress. See `docs/superpowers/`.
