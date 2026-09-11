# Windows desktops as a variant of the existing stack

## Why

The product this is growing into (sihaab.com) promises Windows *and*
Linux desktops in a browser. Today only Linux exists. A spike on
2026-09-11 proved the Windows half is feasible on the current model:
a pre-baked Windows image boots straight into a logged-in desktop,
streams to a browser with nothing installed, and a separate EBS volume
carries the user's files across a full instance terminate-and-relaunch.
It also produced two facts that shape the design:

- **Licensing rules out Windows 11 itself on AWS.** Windows 10/11
  client editions may only run on Dedicated Hosts, BYOL, per named
  user - no spot, no guests, and no AMI exists to launch. **Windows
  Server 2025** is built on Windows 11 24H2, ships the Windows 11
  shell, is license-included, and runs on ordinary spot instances.
  It is the edition used here. The license question is explicitly
  parked, not solved - see Non-goals.
- **Windows costs are driven by vCPU count, not by spot.** The
  Windows license is priced per vCPU and spot does not discount it,
  so a 2-vCPU/8GB instance is half the price of a 4-vCPU/8GB one
  (`m6i.large` $0.103/hr vs `c7i.xlarge` $0.204/hr, Mumbai, Windows
  spot, measured 2026-09-11). Whether 2 vCPU can stream video
  acceptably is the one open question, and it is measured first.

## Goals

- `os = windows` is a per-session choice, threaded through the same
  panel -> workflow -> Terraform -> callback path Linux uses. No
  parallel stack.
- Boots from a baked AMI to a streamable, already-logged-in desktop.
  Target 120-180s (a sysprepped first boot; the un-sysprepped spike
  did 130-169s including a live DCV install).
- Streams through the browser only. Nothing for the user to install.
  No RDP port exposed.
- Files persist on a per-user, per-OS EBS volume; the machine itself
  is disposable. Saving to the obvious places (Desktop, Documents,
  Downloads, Pictures) and browser bookmarks land on that volume
  without the user doing anything.
- Available to **admins only** in this pass, enforced server-side.
- The Linux path is byte-identical when `os = linux`. `terraform plan`
  with the default must show no diff.
- Region: **Mumbai (`ap-south-1`)**, where the stack actually runs
  today. The UAE move is a separate job (see Follow-ons).

## Non-goals

- Solving the Windows edition/licensing question. Server 2025 is the
  working choice; if a real requirement for Windows 11 client appears
  (a specific app, Microsoft Store), that is a Dedicated Host + VM
  Import project with different economics and its own spec.
- Guest or permanent-user access to Windows. The selector is
  admin-only; opening it wider is a one-line policy change later, but
  the cost exposure (3-4x Linux) is a decision for then.
- Whole-machine persistence (installed apps surviving). "Apps persist"
  is delivered by baking a chosen app list into the shared image.
- GPU Windows. `g4dn`/`g5` quota is 0; the `Variant` tag scheme leaves
  room for `windows-gpu` when it isn't.
- The owner's own `desk.*` desktop. Windows is for per-user desktops
  (`username != ""`) only.
- QUIC. DCV's browser client is WebSocket/TCP only; QUIC helps native
  clients, which contradicts browser-only.
- Finishing the UAE migration.

## Architecture

One new axis, `os`, added to the existing `Variant` scheme:

| `os`    | `gpu` | AMI `Variant` tag | instance type          | user-data            |
|---------|-------|-------------------|------------------------|----------------------|
| linux   | false | `cpu`             | `var.instance_type`    | `user-data.sh.tpl`   |
| linux   | true  | `gpu`             | `var.instance_type_gpu`| `user-data.sh.tpl`   |
| windows | false | `windows`         | `var.instance_type_windows` | `user-data.ps1.tpl` |
| windows | true  | `windows-gpu`     | (later)                | (later)              |

Everything else - network stack, per-session security group, DNS
script, volume attachment, password variables, outputs, session-ready
callback, reaper, admin console - is shared and unchanged in shape.

### Streaming layer: Amazon DCV

DCV is AWS's remote display protocol. Chosen over RDP-through-a-gateway
(Guacamole) because the performance benchmark is **video playing in the
remote browser**: RDP degrades to shipping bitmaps for video and a
gateway re-transcodes them, while DCV is a pure H.264 pixel stream
built for exactly that. It is also the cheaper option - no always-on
gateway. Free on EC2; a paid product elsewhere (the AWS-native bet,
noted for the multi-country ambitions).

Facts that constrain the config:

- The browser client is **WebSocket over TCP**. QUIC/UDP is not used.
- DCV on Windows reads its settings from the **SYSTEM account's hive**
  (`HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv`),
  not HKLM. Settings written to HKLM are silently ignored (found in
  the spike).
- **Web port is 443**, not the default 8443. This is what lets the
  existing 443 security-group rules, URL shape and Cloudflare proxying
  apply without change.

## The image (`bake-ami.yml`, `os: windows`)

A second path in the existing bake workflow, selected by a new
`os: linux | windows` input (default `linux`), mirroring the Linux path
step for step.

- **Builder:** on-demand (a bake must not hang on spot capacity),
  latest `Windows_Server-2025-English-Full-Base-*` found by name
  filter (no hardcoded AMI IDs, so a region move is a `region` input),
  50GB gp3 root (base is 30GB; apps and updates need headroom; the
  root is disposable).
- **Provisioning (PowerShell user-data), one-time per image:**
  - DCV server MSI (`https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-server-x64-Release.msi`,
    verified 200), `ADDLOCAL=ALL`.
  - DCV settings in the SYSTEM hive: `session-management/create-session=1`,
    `security/authentication=system`, `connectivity/web-port=443`.
    The console-session owner is set per launch, not here.
  - Windows firewall: allow TCP 443 inbound. Nothing for 3389.
  - Server Manager auto-start off, IE Enhanced Security off, timezone
    `Asia/Dubai`, Windows Update run to completion, automatic reboots
    disabled for runtime.
  - Baked apps via winget: **Google Chrome, VLC, 7-Zip.** (The v1
    list; changing it is a rebake.)
  - Chrome policy `UserDataDir = D:\Profiles\Chrome` so the profile
    follows the user's volume. Set here because it is user-independent.
  - **Sysprep via EC2Launch v2** with shutdown. Required: without it
    every launch would clone the same machine identity and user-data
    would not run on first boot.
- **Output:** `create-image` from the stopped builder, tagged
  `Project=<project>`, `Variant=windows`, `Name=<project>-windows-<timestamp>`,
  then the builder is terminated. Same tag lookup the Linux AMI uses.
- **Not in the image:** any user account, password, or D: state.

Windows activation is AWS KMS-based and survives sysprep; nothing to
do.

## Terraform

New `variable "os"` (string, default `"linux"`, validated to
`linux|windows`). It gates exactly:

1. **AMI lookup** - `tag:Variant` value computed from `os` and `gpu`
   per the table above.
2. **Instance type** - `os == "windows" ? var.instance_type_windows : var.instance_type`.
   `instance_type_windows` defaults to `m6i.large` *provisionally*;
   the measurement task below confirms or changes it. Capacity
   fallback is the existing `use_spot=false` path - on-demand
   `m6i.large` ($0.193) is cheaper than spot 4-vCPU ($0.204), so no
   new mechanism is warranted.
3. **Root volume size** - `var.root_volume_gb_windows`, default 50,
   mirroring `root_volume_gb_gpu`.
4. **User-data** - `templatefile("user-data.ps1.tpl", ...)` wrapped in
   `<powershell>...</powershell>`, passed as plain `user_data_base64`
   (not gzip - EC2Launch v2 does not reliably unpack gzipped
   user-data; the script is a few KB).
5. **Tag** - `OS = var.os` on the instance, for the admin console and
   history.
6. **DNS** - `proxied` is forced `true` when `os = windows` (TLS, below).

Unchanged: `aws_security_group.session_access` and its 443 rules,
`set-dns.sh`, `aws_volume_attachment.guest_data` on `xvdf`,
`web_user` / `web_password_override`, outputs (`url`, `admin_password`,
`instance_id`, `public_ip`).

Windows is only valid with `username != ""`; `os = windows` with an
empty username is a validation error.

### `user-data.ps1.tpl` (per launch)

Inputs: `username`, `password`, `hostname`.

1. **Data volume -> D:** RAW disk (first ever boot for this user) ->
   initialise GPT, one NTFS partition, label `UserData`, letter D.
   Already-formatted disk -> assign D. Never formats a non-RAW disk.
2. **Known-folder redirection:** `Desktop`, `Personal` (Documents),
   `{374DE290-...}` (Downloads), `My Pictures` under
   `HKCU\...\Explorer\User Shell Folders` for the desktop user ->
   `D:\<Folder>`, created if absent. Applied via the default-user
   hive before first logon so it takes effect on the auto-logon.
3. **Local account:** create (or set password of) the desktop user
   named after `username` (Windows local names: <=20 chars; the panel
   username is already a DNS label, which satisfies the character
   rules), member of Administrators, password never expires.
4. **Auto-logon:** Winlogon `AutoAdminLogon=1`, `DefaultUserName`,
   `DefaultPassword`, `DisableCAD=1`, legal-notice keys cleared.
5. **DCV console session owner** = that user (SYSTEM hive,
   `automatic-console-session/owner`), then restart `dcvserver`.
6. Transcript to `C:\desktop-setup.log` for SSM-based debugging.

## TLS and access path

The Windows hostname is **always Cloudflare-proxied**. The browser sees
Cloudflare's trusted certificate; Cloudflare connects to DCV's
self-signed certificate on the origin over HTTPS. Requirements:

- Zone SSL mode **Full** (not *Full (strict)*, which rejects
  self-signed origins; not *Flexible*, which would send plain HTTP to
  an HTTPS-only origin). Verified as the first task of the plan; the
  existing Caddy-fronted Linux hosts work under Full.
- Because the record is proxied, the session security group uses the
  **existing Cloudflare-only 443 ingress rule**. A Windows desktop is
  not reachable by direct IP. This is a deliberate tightening relative
  to the Linux default.
- Cloudflare proxies WebSockets; DCV's keepalives keep the connection
  alive. The Linux `enable_access=true` path already runs Selkies'
  WebSocket through the same proxy, so this is a known-good pattern.
- Optional Cloudflare Access (`enable_access`) works identically.

Login is DCV's own page, authenticating against the Windows local
account. Username and password are the same ones the panel already
shows for a Linux session.

## Persistence

**One volume per (user, OS).** Linux volumes are ext4 carrying
containerd state; Windows needs NTFS. They cannot be shared.

- Role tag `desktop-guest-data` -> Linux (unchanged).
- Role tag `desktop-guest-data-windows` -> Windows. 20GB gp3,
  encrypted, same AZ rule, ~$1.82/month in Mumbai.
- `desktop-up.yml`'s lookup-or-create keys on `Owner` + `Role`; the
  role is selected by `os`. The password-stored-on-the-volume-tag
  pattern is reused per volume, so a user's Windows password is stable
  across their Windows sessions independently of their Linux one.
- `desktop-wipe.yml` learns the second role and wipes both, so "delete
  my data" means all of it.

What persists: everything on D: - redirected known folders, the Chrome
profile, anything the user puts there. What does not: anything
installed or changed on C:.

## Panel and workflows

- **`desktop-up.yml`:** new inputs `os` (choice `linux|windows`,
  default `linux`) -> `TF_VAR_os`, and `instance_type_windows`
  (default `m6i.large`) -> `TF_VAR_instance_type_windows`; volume
  role chosen by `os`. The existing `instance_type` input stays
  Linux-only. **No secret passes through any input** (public repo).
- **`desktop-down.yml`, `desktop-reaper.yml`:** no change. Both key on
  `Role=guest-desktop`/state keys that are OS-agnostic.
- **`panel/api/dispatch.js`:** `os = session.is_admin && body.os === "windows" ? "windows" : "linux"`,
  enforced server-side exactly like `persist`; stored on the session
  hash; passed as the `os` dispatch input.
- **`panel/public/app.js`:** an OS selector rendered only when
  `session.is_admin`. Everyone else sees the page exactly as today.
- **`panel/lib/desktops.js`:** `HOURLY_USD_WINDOWS` (default 0.103)
  alongside `HOURLY_USD`; the rate shown follows the session's `os`.
- **Admin console / history:** show `os` per session.

## Measurement task (first in the plan, after the bake)

Start two Windows sessions, `m6i.large` and `c7i.xlarge` (via the
`instance_type_windows` workflow input), play the same
1080p video in the remote Chrome for two minutes each, and read DCV's
frame-rate and latency counters from the client's stats overlay. Record
the numbers in the plan.

- 2 vCPU holds ~30fps with usable input latency -> `instance_type_windows = m6i.large`,
  and the panel rate is $0.103.
- It does not -> `instance_type_windows = c7i.xlarge`, rate $0.204,
  and the economics note in Costs applies.

## Costs (Mumbai, Windows spot, 2026-09-11)

| Instance      | vCPU | RAM | $/hr  | 4h/day, 22 days | + 20GB volume |
|---------------|------|-----|-------|-----------------|---------------|
| `m6i.large`   | 2    | 8GB | 0.103 | $9.10           | **$10.92**    |
| `c7i.xlarge`  | 4    | 8GB | 0.204 | $17.98          | $19.80        |
| `g4dn.xlarge` | 4+T4 | 16GB| 0.250 | $21.96          | $23.78 (quota 0) |

For reference Linux `c7i.xlarge` spot is $0.053/hr. Windows is
2-4x Linux at any size; the vCPU count is the lever.

## Error handling

- **Spot capacity** (`InsufficientInstanceCapacity`, seen in the spike
  on relaunch): existing `use_spot=false` retry; the AZ is pinned by
  the volume, so a type change is the only other lever and is a
  manual `instance_type` input for now.
- **Volume attach before user-data:** attachment is a Terraform
  resource on the same apply as the instance; EC2Launch runs user-data
  after Windows boots (minutes later), so the disk is present. If it
  is not, user-data logs and continues without D: rather than failing
  the session; the panel still gets a URL.
- **Callback:** unchanged - `session-ready` is posted only after apply
  succeeds; Windows' longer boot is covered because `url` is polled
  for `/healthz`... **which DCV does not serve.** The panel's `urlUp`
  check must accept DCV's root (`/`, HTTP 200) for Windows sessions,
  keyed on the session's `os`. This is the one panel change with
  correctness weight.
- **Cloudflare SSL mode wrong:** the symptom is a 526/525 from
  Cloudflare, not a DCV error. Checked up front; documented in the
  runbook section of the plan.

## Testing / proof

In order, each gating the next:

1. Bake completes; AMI tagged `Variant=windows` visible in Mumbai.
2. `terraform validate`; `terraform plan` with defaults (`os=linux`)
   shows **no changes** against a live Linux state - the regression
   guard.
3. `terraform plan` with `os=windows`, a test username, selects the
   Windows AMI, `m6i.large`, 50GB root, PowerShell user-data.
4. From `desktop.mnour.dev` signed in as an admin: OS selector visible;
   Start Windows -> `session-ready` arrives with URL and password ->
   the URL opens through Cloudflare **with no certificate warning** ->
   DCV login with the shown credentials -> desktop is logged in ->
   D: present; Documents and Downloads resolve to D:; Chrome opens and
   its profile is on D:.
5. Save a file, bookmark a page. Destroy from the panel. Start Windows
   again. File and bookmark are present. Boot time recorded.
6. Signed in as a non-admin: no selector; a hand-crafted
   `{os:"windows"}` dispatch yields a Linux session.
7. Direct `https://<public-ip>` to the Windows instance is refused
   (Cloudflare-only security group).
8. Measurement task numbers recorded; `instance_type_windows` set.
9. Wipe from the panel removes the Windows volume; a Linux volume for
   the same user is untouched unless also selected.

## Follow-ons (not this spec)

- **UAE migration:** bake `cpu` and `windows` in `me-central-1`, flip
  `region`/`AWS_REGION`, verify Start for both OSes in one pass.
- **GPU vCPU quota request** (`L-3819A6DF`) - unlocks `windows-gpu`
  and the site's A10G claim.
- Opening Windows to permanent users / guests (policy flag in KV,
  reaper limit per OS, cost display).
- `sihaab.com` domain cut-over (separate, already scoped).
