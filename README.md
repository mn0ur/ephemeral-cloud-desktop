# Ephemeral Cloud Desktop

A full Linux desktop in the browser, provisioned on AWS with Terraform. One
click up, one click down. Installed software, files and browser sessions
survive teardown. When it is down it costs about **$1.90/month**.

Live at `desk.mnour.sd`, controlled from `hub.mnour.sd/control`.

## Why this exists

I wanted a disposable cloud desktop I could actually use — audio, video, real
applications — without paying for an idle instance. The interesting engineering
is not the desktop. It is making compute genuinely disposable **while keeping
state**, and that turned out to be much harder than it looks.

## What it actually runs

    PERSISTENT — never destroyed              EPHEMERAL — destroyed every session
    ──────────────────────────────            ───────────────────────────────────
    S3      terraform state                   VPC, subnet, IGW, security group
    EBS     20GB gp3 volume                   EC2 c7i.xlarge SPOT
              /config    desktop home         Caddy      TLS termination
              containerd images + layers      Docker     linuxserver/webtop
              caddy      TLS certificates                Debian 13 + KDE Plasma 6
    random_password  credentials                         Selkies streaming engine

    Cloudflare A record, updated in place — never deleted

Four Terraform stacks with deliberately different lifecycles:

| Stack | Contains | Lifecycle |
|---|---|---|
| `terraform/bootstrap` | S3 state + data buckets | apply once |
| `terraform/persistent` | 20GB volume, credentials | **never destroyed** |
| `terraform/` | desktop VPC, SG, instance, DNS | destroyed freely |
| `terraform/hub` | always-on control box | always up |

`prevent_destroy` inside the desktop stack would make `terraform destroy`
*fail* rather than skip it — which is precisely why the volume lives in a
separate stack. One-command teardown has to actually work.

## The hard part: persistence

Getting "everything survives destroy" right took four corrections. Every one of
them was a mechanism **reporting success while doing nothing**:

**1. The mount that succeeded without mounting.** The volume's label didn't
match the fstab entry. Because the options included `nofail`, `mount` returned
**exit 0**, so `set -e` caught nothing and Docker wrote 4.2GB to the ephemeral
root disk with no error anywhere. A safety option had converted a hard failure
into a silent one. Fixed with UUID-based fstab and an explicit assertion —
`findmnt` must confirm the mount or the boot aborts.

**2. `data-root` moved 976KB of 5.8GB.** Ubuntu's `docker.io` uses the
containerd snapshotter, so image and container layers live in
`/var/lib/containerd` — which Docker's `data-root` does not control. `docker
info` cheerfully reported the correct path. Symptom: a 2GB image re-pulled
every boot and `apt install` silently lost on destroy. Fixed by bind-mounting
`/var/lib/containerd` onto the volume before containerd starts, asserted by
comparing filesystem **device IDs** rather than trusting `docker info`.

**3. Let's Encrypt ran out.** Caddy stored certificates on the ephemeral disk,
so every rebuild requested a fresh one. The limit is **5 certificates per
hostname per 168 hours** — five rebuilds in one afternoon locked the hostname
out for a day. Fixed with `XDG_DATA_HOME` pointed at the volume.

**4. `systemctl reload` failed silently.** An unquoted heredoc expanded `$2`,
`$1` and `$4` inside a bcrypt hash, leaving an 11-character fragment. Caddy
rejected the config, `reload` reported success, and Caddy kept serving the
*previous* config. The fault sat undetected until a restart forced it to load
and took the dashboard down. Fixed with a quoted heredoc, a hash-format
assertion, and `caddy validate` gating the restart.

**The pattern:** none of these were caught by reading code or checking status.
All were caught by measuring the outcome — `findmnt`, device IDs, `du -x`,
installing a package and looking for it after a destroy.

> If it should outlive the machine, it belongs in the stack that outlives the
> machine.

Applied three times before it stuck: data, then certificates, then credentials.

**Verified by a real destroy/apply cycle:** the same container id came back, a
package installed before teardown was still present, zero certificate requests,
and **boot to ready fell from 195s to 20s**.

## Design decisions worth defending

**No NAT Gateway.** It costs $0.045/hr plus data processing — more than the
instance it would serve. A public subnet with a public IP used for egress does
the job. (Corollary learned later: this also means the public IP *cannot* be
removed. An Internet Gateway NATs using the instance's own public address, so
"put it behind a tunnel to drop the IP" does not work without paying for NAT.)

**No Elastic IP on the desktop.** An EIP bills whether attached or not, and the
desktop's address changes every session anyway. DNS is updated in place instead.

**DNS is updated, never deleted.** Deleting the record on teardown caused
NXDOMAIN responses to be cached for ~30 minutes, so the *next* session was
unreachable long after it was healthy. Teardown now parks the record at
`192.0.2.1` — RFC 5737 TEST-NET-1, guaranteed unroutable.

**Spot instances.** ~$0.10/hr against ~$0.19 on-demand for `c7i.xlarge`.

**Non-burstable instance family.** `t3` is cheaper but burstable: sustained
video encoding exhausts CPU credits and the desktop degrades exactly when it is
being used. Dedicated vCPU is a requirement, not a preference.

**S3 native state locking.** `use_lockfile` rather than a DynamoDB lock table —
the DynamoDB pattern is deprecated in current Terraform, and this is one fewer
resource to create, secure and bill.

**No secrets through workflow inputs.** This repository is public. GitHub echoes
each step's `env:` block into job logs and does **not** mask `inputs.*` — only
`secrets.*`. `::add-mask::` cannot rescue it either, because the `run:` script
that would perform the masking is itself echoed. The password input was removed
and credentials are generated by `random_password` in the persistent stack.

**Completion is judged by the desktop answering, not by the workflow finishing.**
Terraform exits well before TLS settles. The control panel polls `/healthz`
until it returns 200, then redirects.

**webtop over neko.** neko was built first and worked. webtop won on audio and
microphone by default, a tunable encoder, and — critically — **a single TCP
port instead of a 100-port UDP range**, which is what made it possible to put a
CDN in front. Also worth recording: neko's multiuser provider defaults
`admin_profile` to `"{}"`, which unmarshals to a struct where every bool
including `can_host` is false. Video renders perfectly and every click is
silently ignored, with nothing logged, because "can watch but not host" is a
legitimate state. Diagnosed by running `neko serve --help` inside the
container, not from the docs.

## Cost

| State | Measured |
|---|---|
| Running (`c7i.xlarge` spot, eu-central-1) | **$0.104/hr** |
| 2 hr/day × 20 days | ~$4.16/month |
| Destroyed | **~$1.90/month** — the 20GB volume, nothing else |

That $1.90 is the price of "destroy the machine, keep the work". It is a
deliberate trade, not overhead.

## Known gaps

Stated plainly rather than omitted.

- **The desktop is internet-facing.** The security group allows 80 and 443 from
  `0.0.0.0/0`; Caddy basic auth is the only barrier, and the container has
  passwordless `sudo`. Cloudflare Access is the intended fix and is **blocked** —
  the account role is *Limited Account-Level Access* and cannot enable Zero Trust.
- **GitHub Actions uses static AWS keys.** OIDC is the intended design and needs
  `iam:CreateRole`, which this IAM user is denied. The scoped policy is written
  and ready at `docs/aws-permissions-policy.json`, awaiting an account admin.
- **No SSM.** Same missing permission. Debugging uses SSH on port 22 behind a
  feature flag (`enable_ssh`), off by default.
- **Region is `eu-central-1`, not `me-central-1`.** Abu Dhabi is ~5–15ms from
  the UAE region against ~110–130ms to Frankfurt, and spot is ~16% cheaper
  there. On 2026-08-08 `me-central-1` returned `RequestLimitExceeded` on
  `RunInstances` for every instance type tested while the identical call
  succeeded in Frankfurt. Moving back is a variable change.
- **No automatic teardown.** Nothing destroys an idle desktop. A forgotten
  session bills $0.104/hr indefinitely.
- **Package installs are not declarative.** They persist on the volume, which
  is what was wanted, but they are not recorded anywhere reviewable. Capturing
  them into a file and raising a pull request remains the intended answer.

## Repository

    terraform/            desktop stack
    terraform/persistent/ volume + credentials, never destroyed
    terraform/bootstrap/  state buckets
    terraform/hub/        always-on control box
    hub/control/          stdlib-only control panel (start/destroy, live progress)
    .github/workflows/    manual-dispatch START and DESTROY
    scripts/set-dns.sh    in-place Cloudflare record update
    docs/                 design spec, plan, IAM policy
