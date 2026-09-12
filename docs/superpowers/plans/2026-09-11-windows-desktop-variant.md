# Windows Desktop Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `os = windows` as a per-session choice (admin-only) that boots a baked Windows Server 2025 image, streams it through the browser via Amazon DCV on 443, and keeps the user's files on a per-user NTFS volume — through the same panel → workflow → Terraform → callback path Linux uses.

**Architecture:** One new axis, `os`, on the existing `Variant` tag scheme. `bake-ami.yml` gains a Windows path producing `Variant=windows`. Terraform gates AMI, instance type, root size, user-data (PowerShell), an `OS` tag and forced Cloudflare proxying on `var.os`. The panel enforces admin-only server-side and probes DCV's root instead of `/healthz`. Everything else — network stack, per-session SG, DNS script, volume attachment, password flow, reaper — is shared.

**Tech Stack:** GitHub Actions, Terraform 1.15 (AWS + Cloudflare providers, S3 backend), PowerShell 5.1 on Windows Server 2025 via EC2Launch v2, Amazon DCV 2024+, Vercel serverless (Node 22, plain JS, `node --test`), Upstash Redis.

**Spec:** `docs/superpowers/specs/2026-09-11-windows-desktop-variant-design.md`

## Global Constraints

- Region is **Mumbai (`ap-south-1`)**, AZ `ap-south-1c` for volumes (`AWS_AZ` in `desktop-up.yml` is the single source of truth). Nothing in this plan touches region defaults.
- **No secret passes through a `workflow_dispatch` input** — the repo is public. Passwords flow via `TF_VAR_web_password_override` from the volume tag, exactly as today.
- **The Linux path is byte-identical when `os = linux`.** `terraform plan` with defaults must show no resource-level diff versus the pre-change baseline (Task 2 records it).
- DCV settings on Windows live in the **SYSTEM hive** `Registry::HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv`, never `HKLM`.
- DCV web port is **443**. No 8443, no 3389, no UDP.
- Windows hostnames are **always Cloudflare-proxied** and their security group is **Cloudflare-only** on 443.
- Windows is valid only for `username != ""`. The owner's `desk.*` desktop stays Linux.
- Windows sessions are **admin-only**, enforced in `panel/api/dispatch.js`.
- Per-user, per-OS volumes: `Role=desktop-guest-data` (Linux, 15 GB) and `Role=desktop-guest-data-windows` (Windows, 20 GB).
- Security-group descriptions: **no apostrophes** (AWS rejects them at apply time only).
- Commit messages end with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- Never print a password value into a workflow log or step summary (`::add-mask::` before any echo that could carry it).
- Do not delete EBS volumes from a task. Volumes created for testing are listed for the owner to delete.

## Deviations from the spec, decided here (update the spec in Task 11)

1. **Apps are installed from vendor MSIs, not winget.** winget is an MSIX per-user app and does not run reliably under SYSTEM (which is what EC2Launch user-data runs as). Chrome enterprise MSI, 7-Zip MSI, VLC MSI from videolan's `last/win64/` index.
2. **No Windows Update pass during the bake.** AWS republishes the base AMI monthly with patches; a PSWindowsUpdate install adds a PSGallery dependency and 10+ minutes for no gain. Automatic reboots are disabled at runtime as the spec says.
3. **Local password-complexity policy is disabled in the image.** The workflow's stored passwords are 32 hex characters (two character classes); Windows' default policy demands three, and `New-LocalUser` would fail. 128 bits of entropy from `openssl rand -hex 16` is not made weaker by this.
4. **Cloudflare zone SSL mode is already `full`** (verified 2026-09-11 via API). Task 2 re-verifies; no change task.

## File Structure

| File | Responsibility |
|---|---|
| `.github/workflows/bake-ami.yml` (modify) | `os` input; Windows branch: base AMI by name, `scripts/bake-windows.ps1` as user-data, wait for sysprep shutdown, image tagged `Variant=windows` |
| `scripts/bake-windows.ps1` (create) | One-time image provisioning: DCV, desktop-feel, password policy, apps, sysprep |
| `terraform/user-data.ps1.tpl` (create) | Per-launch: D: volume, known-folder redirection, local user, auto-logon, DCV session owner |
| `terraform/variables.tf` (modify) | `os`, `instance_type_windows`, `root_volume_gb_windows` |
| `terraform/access.tf` (modify) | `local.windows`, `local.proxied`, `local.windows_user` next to `access_enabled` |
| `terraform/main.tf` (modify) | AMI variant, instance type, user-data switch, root size, `OS` tag, precondition, SG + DNS use `local.proxied` |
| `terraform/outputs.tf` (modify) | `login_user` |
| `.github/workflows/desktop-up.yml` (modify) | `os` + `instance_type_windows` inputs, volume role/size by OS, TF_VARs, `login_user` in callback, summary |
| `.github/workflows/desktop-wipe.yml` (modify) | Deletes both roles |
| `panel/lib/desktops.js` (modify) | `HOURLY_USD_WINDOWS`, `hourlyRate`, `requestedOs`, `probeUrl`; `urlUp` takes the full probe URL |
| `panel/test/desktops.test.js` (create) | `node --test` for the pure helpers |
| `panel/package.json` (modify) | `test` script |
| `panel/api/dispatch.js` (modify) | server-side `os` policy, session field, dispatch input |
| `panel/api/session-ready.js` (modify) | carries `os`, stores `login_user` |
| `panel/api/status.js` (modify) | `hourly_usd_windows` |
| `panel/public/app.js` (modify) | admin-only OS selector; Windows credentials card; no Basic-Auth URL for Windows; per-OS rate |
| `panel/public/admin.js` (modify) | shows `os` per session |
| `README.md`, spec (modify) | Windows section; deviations |

---

### Task 1: Branch, stash unrelated WIP, Windows bake path — and kick the bake off

The bake takes ~30 minutes of wall-clock and nothing else in this plan can be *verified* against AWS until an AMI exists, so it runs first, from the branch, in the background.

**Files:**
- Create: `scripts/bake-windows.ps1`
- Modify: `.github/workflows/bake-ami.yml`

**Interfaces:**
- Produces: an AMI in `ap-south-1` tagged `Project=ephemeral-desktop`, `Variant=windows`, name `ephemeral-desktop-baked-windows-<stamp>`; DCV listening on 443 with `authentication=system`; Chrome policy `UserDataDir=D:\Profiles\Chrome\${user_name}`; `PasswordComplexity=0`.

- [ ] **Step 1: Branch and stash the unrelated `PANEL_URL` edit**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
git stash push -m "wip: PANEL_URL var for sihaab.com domain work" -- .github/workflows/desktop-up.yml
git status --porcelain   # expected: empty
git checkout -b feat/windows-variant main
```

- [ ] **Step 2: Verify the three download URLs still answer before baking them in**

```bash
for U in \
  "https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-server-x64-Release.msi" \
  "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" \
  "https://www.7-zip.org/a/7z2409-x64.msi"; do
  printf "%-95s " "$U"; curl -s -o /dev/null -w "%{http_code}\n" -I -L "$U"
done
curl -s https://download.videolan.org/pub/videolan/vlc/last/win64/ | grep -o 'vlc-[0-9.]*-win64\.msi' | head -1
```
Expected: three `200`s and one `vlc-<version>-win64.msi` line. If 7-Zip returns 404, replace `7z2409` with the current version from https://www.7-zip.org/download.html in the script below.

- [ ] **Step 3: Write `scripts/bake-windows.ps1`**

```powershell
<powershell>
# One-time provisioning of the Windows desktop image. Runs as SYSTEM under
# EC2Launch v2 on a throwaway builder; ends by sysprepping and SHUTTING DOWN,
# and the stopped state is the completion signal bake-ami.yml waits for.
#
# Nothing user-specific belongs here - no accounts, no passwords, no D:.
# Those are per launch, in terraform/user-data.ps1.tpl.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Start-Transcript -Path C:\bake.log -Append

function Get-File($Url, $Out) {
  Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
}
function Install-Msi($Path) {
  $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$Path`" /quiet /norestart"
  if ($p.ExitCode -notin 0, 3010) { throw "msiexec $Path exited $($p.ExitCode)" }
}

# ---------------------------------------------------------------------------
# 1. Amazon DCV. Free on EC2 (no licence server). Settings go in the SYSTEM
#    hive - dcvserver never reads HKLM, and writing there looks correct while
#    doing nothing (found the hard way in the 2026-09-11 spike).
# ---------------------------------------------------------------------------
Get-File "https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-server-x64-Release.msi" C:\dcv.msi
Install-Msi C:\dcv.msi
$dcv = "Registry::HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv"
foreach ($k in "session-management", "session-management\automatic-console-session", "security", "connectivity") {
  New-Item -Path "$dcv\$k" -Force | Out-Null
}
Set-ItemProperty "$dcv\session-management" "create-session" 1 -Type DWord
Set-ItemProperty "$dcv\security" "authentication" "system" -Type String
# 443, not DCV's default 8443: the existing security-group rules, URL shape
# and Cloudflare proxying all assume 443. Nothing else listens there on a
# fresh Server install.
Set-ItemProperty "$dcv\connectivity" "web-port" 443 -Type DWord
New-NetFirewallRule -DisplayName "DCV web 443" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null

# ---------------------------------------------------------------------------
# 2. Make a Server install feel like a desktop.
# ---------------------------------------------------------------------------
New-Item -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\ServerManager" "DoNotOpenServerManagerAtLogon" 1 -Type DWord
foreach ($g in "{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}", "{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}") {
  $p = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$g"
  if (Test-Path $p) { Set-ItemProperty $p "IsInstalled" 0 -Type DWord }
}
Set-TimeZone -Id "Arabian Standard Time"

# Windows Update may install, never reboot under a logged-on user - a session
# vanishing mid-work is worse than a pending patch.
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoRebootWithLoggedOnUsers" 1 -Type DWord

# Password complexity OFF. desktop-up.yml stores each user's password as 32
# hex characters (two character classes); the default policy demands three
# and New-LocalUser would refuse it at every launch. 128 bits of entropy is
# not weakened by turning the class rule off.
secedit /export /cfg C:\secpol.cfg | Out-Null
(Get-Content C:\secpol.cfg) -replace 'PasswordComplexity = 1', 'PasswordComplexity = 0' | Set-Content C:\secpol.cfg
secedit /configure /db C:\Windows\security\local.sdb /cfg C:\secpol.cfg /areas SECURITYPOLICY | Out-Null
Remove-Item C:\secpol.cfg -Force

# ---------------------------------------------------------------------------
# 3. Baked apps. Vendor MSIs, not winget: winget is a per-user MSIX app and
#    does not run reliably as SYSTEM. This list is "apps persist" for v1.
# ---------------------------------------------------------------------------
Get-File "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" C:\chrome.msi
Install-Msi C:\chrome.msi
# Profile on the user's persistent volume, so bookmarks and logins survive
# the instance. ${user_name} is expanded by Chrome, not by us. user-data
# removes this policy on a session that has no D: (persist=false), otherwise
# Chrome would refuse to start.
New-Item -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Google\Chrome" "UserDataDir" 'D:\Profiles\Chrome\${user_name}' -Type String

Get-File "https://www.7-zip.org/a/7z2409-x64.msi" C:\7z.msi
Install-Msi C:\7z.msi

try {
  $idx = (Invoke-WebRequest "https://download.videolan.org/pub/videolan/vlc/last/win64/" -UseBasicParsing).Content
  $m = [regex]::Match($idx, 'vlc-[\d\.]+-win64\.msi')
  if ($m.Success) {
    Get-File "https://download.videolan.org/pub/videolan/vlc/last/win64/$($m.Value)" C:\vlc.msi
    Install-Msi C:\vlc.msi
  } else { Write-Output "VLC: no msi in index, skipped" }
} catch { Write-Output "VLC skipped: $_" }   # a bake must not fail for VLC

Remove-Item C:\*.msi -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4. Sysprep + shutdown. Without sysprep every launch would clone this
#    machine's identity and EC2Launch would not run user-data on first boot.
# ---------------------------------------------------------------------------
Write-Output "bake-complete"
Stop-Transcript
& "$env:ProgramFiles\Amazon\EC2Launch\EC2Launch.exe" sysprep --shutdown=true
</powershell>
```

- [ ] **Step 4: Add the `os` input and the Windows branch to `bake-ami.yml`**

In `.github/workflows/bake-ami.yml`, under `inputs:` after the `gpu` input add:

```yaml
      os:
        description: "Which desktop to bake. linux (default) is the webtop/Selkies image; windows bakes Windows Server 2025 + Amazon DCV from scripts/bake-windows.ps1 and produces Variant=windows. gpu is ignored for windows in this pass."
        type: choice
        options: [linux, windows]
        default: linux
```

Replace the step `Read the desktop image from terraform, the single source of truth` header with a conditional so the Linux-only image lookup is skipped for Windows:

```yaml
      - name: Read the desktop image from terraform, the single source of truth
        if: inputs.os != 'windows'
```

Replace the whole `Launch a throwaway instance in the default VPC` step with two steps (the Linux one is the existing body unchanged apart from the `if:`):

```yaml
      - name: Launch a throwaway instance in the default VPC (linux)
        if: inputs.os != 'windows'
        run: |
          # ... existing Linux body, unchanged ...

      - name: Launch a throwaway instance in the default VPC (windows)
        if: inputs.os == 'windows'
        run: |
          set -euo pipefail
          # Latest AWS-published Server 2025 base, by name: no AMI IDs to
          # hunt down on a region move.
          BASE_AMI=$(aws ec2 describe-images --owners amazon \
            --filters "Name=name,Values=Windows_Server-2025-English-Full-Base-*" "Name=state,Values=available" \
            --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
          echo "base AMI: $BASE_AMI"
          SUBNET=$(aws ec2 describe-subnets \
            --filters "Name=default-for-az,Values=true" \
            --query 'Subnets[0].SubnetId' --output text)

          # On-demand, not spot: a bake that hangs on capacity helps nobody.
          # m6i.large is the size the desktop will run on; ~$0.19/hr Windows
          # on-demand, and a bake is ~30 minutes.
          INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$BASE_AMI" --instance-type m6i.large \
            --subnet-id "$SUBNET" --associate-public-ip-address \
            --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=50,VolumeType=gp3,DeleteOnTermination=true}" \
            --user-data file://scripts/bake-windows.ps1 \
            --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ami-bake-temp-windows}]' \
            --query 'Instances[0].InstanceId' --output text)
          echo "INSTANCE_ID=$INSTANCE_ID" >> "$GITHUB_ENV"
          aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
```

Add `if: inputs.os != 'windows'` to the existing `Wait for the image pull to finish` step, and add this new step after it:

```yaml
      - name: Wait for sysprep to shut the builder down (windows)
        if: inputs.os == 'windows'
        run: |
          # The Windows bake ends with EC2Launch sysprep --shutdown, so
          # "stopped" IS the completion signal - no console marker to grep.
          # DCV + Chrome + 7-Zip + VLC + sysprep comfortably fits 30 minutes;
          # 45 is the ceiling, after which something is wrong and snapshotting
          # a half-provisioned image would only move the failure to every boot.
          for i in $(seq 1 90); do
            STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
              --query 'Reservations[0].Instances[0].State.Name' --output text)
            echo "$(date -u +%H:%M:%S) builder is $STATE"
            if [ "$STATE" = "stopped" ]; then break; fi
            if [ "$STATE" = "terminated" ]; then echo "::error::builder terminated before sysprep finished"; exit 1; fi
            sleep 30
          done
          if [ "$STATE" != "stopped" ]; then
            echo "::error::builder did not reach stopped within 45 minutes - refusing to snapshot"
            exit 1
          fi
```

In `Snapshot into an AMI`, replace the `VARIANT=` line with:

```bash
          if [ "${{ inputs.os }}" = "windows" ]; then
            VARIANT=windows
          else
            VARIANT=$([ "${{ inputs.gpu }}" = "true" ] && echo gpu || echo cpu)
          fi
```

- [ ] **Step 5: Validate the YAML parses and commit**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/bake-ami.yml')); print('yaml ok')"
git add scripts/bake-windows.ps1 .github/workflows/bake-ami.yml
git commit -m "feat(bake): Windows Server 2025 + DCV image path (Variant=windows)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push -u origin feat/windows-variant
```

- [ ] **Step 6: Start the bake from the branch, in the background**

```bash
gh workflow run bake-ami.yml --ref feat/windows-variant -f os=windows -f region=ap-south-1
sleep 10
gh run list --workflow=bake-ami.yml --limit 1 --json databaseId,status,headBranch
```
Note the run id. Do not wait here — continue to Task 2. Task 3 Step 6 waits on it.

---

### Task 2: Terraform baseline (regression guard) and Cloudflare re-check

**Files:** none modified. Produces `/tmp/claude-1000/-home-mn/55650e4a-fb0d-48ff-ab35-8e33e1fbb48d/scratchpad/plan-baseline.txt`.

- [ ] **Step 1: Confirm the zone SSL mode is `full`**

```bash
T=$(cat ~/.config/cloudflare/token)
curl -s "https://api.cloudflare.com/client/v4/zones/c010382ec0c681396eeb999ef6454769/settings/ssl" \
  -H "Authorization: Bearer $T" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['value'])"
```
Expected: `full`. If `strict`, stop and report — the design requires Full.

- [ ] **Step 2: Record the pre-change Linux plan against a scratch state key**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
git stash list | head -2   # the PANEL_URL stash must still be there, untouched
export CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/token)
export AWS_DEFAULT_REGION=ap-south-1
terraform -chdir=terraform init -input=false -reconfigure -backend-config="key=desktop/user-plancheck/terraform.tfstate" >/dev/null
terraform -chdir=terraform plan -input=false -no-color -lock=false \
  -var username=plancheck -var owner_email=plancheck@example.com \
  -var web_user=plancheck -var web_password_override=plancheckpassword \
  -var cloudflare_dns_api_token=x \
  | sed -E 's/\(known after apply\)/KAA/; /^Plan:/!{/^ *[+~-]? *(id|arn|.*_at) /d}' \
  > /tmp/claude-1000/-home-mn/55650e4a-fb0d-48ff-ab35-8e33e1fbb48d/scratchpad/plan-baseline.txt
grep '^Plan:' /tmp/claude-1000/-home-mn/55650e4a-fb0d-48ff-ab35-8e33e1fbb48d/scratchpad/plan-baseline.txt
```
Expected: a `Plan: N to add, 0 to change, 0 to destroy.` line. Record N. (`plancheck` never applies; the key holds no state.)

---

### Task 3: Terraform variant

**Files:**
- Create: `terraform/user-data.ps1.tpl`
- Modify: `terraform/variables.tf` (after `variable "instance_type_gpu"`, ~line 183), `terraform/access.tf:20`, `terraform/main.tf:279-300, 305-307, 325-338, 346-348, 372-385, 147-172, 432-448`, `terraform/outputs.tf`

**Interfaces:**
- Consumes: AMI `Variant=windows` (Task 1).
- Produces: `var.os` (`"linux"|"windows"`), `var.instance_type_windows`, `var.root_volume_gb_windows`, `local.windows`, `local.proxied`, `local.windows_user`, `output "login_user"`, instance tag `OS`.

- [ ] **Step 1: Add the variables** (append after `variable "instance_type_gpu"`):

```hcl
variable "os" {
  description = <<-EOT
    Which desktop to run. "linux" (default) is the webtop/Selkies container,
    unchanged. "windows" boots the baked Windows Server 2025 + Amazon DCV
    image (Variant=windows) on instance_type_windows, streams DCV on 443
    behind a Cloudflare-proxied hostname, and mounts the user's NTFS volume
    as D:. Only valid with a username - the owner's own desktop is Linux.
  EOT
  type        = string
  default     = "linux"
  validation {
    condition     = contains(["linux", "windows"], var.os)
    error_message = "os must be \"linux\" or \"windows\"."
  }
}

variable "instance_type_windows" {
  description = <<-EOT
    Used when os = windows. Windows' licence is priced per vCPU and spot does
    not discount it, so 2 vCPU / 8GB (m6i.large, $0.103/hr spot in
    ap-south-1 on 2026-09-11) is half the price of 4 vCPU / 8GB
    (c7i.xlarge, $0.204). Whether 2 vCPU streams 1080p video acceptably is
    the measured question - see the plan; change this default from that
    measurement, not by guess.
  EOT
  type        = string
  default     = "m6i.large"
}

variable "root_volume_gb_windows" {
  description = "Root size when os = windows. The Server 2025 base is 30GB; Chrome, 7-Zip, VLC and updates need headroom. Disposable - nothing a user keeps lives on C:."
  type        = number
  default     = 50
}
```

- [ ] **Step 2: Add the locals in `terraform/access.tf`** — directly after the existing `access_enabled = ...` line (line 20), inside the same `locals` block:

```hcl
  windows = var.os == "windows"

  # A Windows hostname is ALWAYS proxied: DCV presents a self-signed
  # certificate and the browser must see Cloudflare's trusted one instead.
  # (Zone SSL mode must be "Full" - not "Full (strict)" - for that to work.)
  # Proxied also means the security group only admits Cloudflare's edge, so
  # a Windows desktop is unreachable by direct IP. Linux keeps following
  # access_enabled exactly as before.
  proxied = local.access_enabled || local.windows

  # Windows local account names are limited to 20 characters; the panel
  # username (an email local part) is already a valid DNS label, which
  # satisfies the character rules, but not the length.
  windows_user = substr(var.web_user, 0, 20)
```

- [ ] **Step 3: Write `terraform/user-data.ps1.tpl`**

```powershell
<powershell>
# Per-launch setup for a Windows desktop. Runs once, as SYSTEM, on first boot
# of a sysprepped image (terraform/../scripts/bake-windows.ps1). Everything
# user-specific lives here; everything shared lives in the image.
#
# Terraform templatefile: only "$${" is escaped; plain "$Var" is PowerShell.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
Start-Transcript -Path C:\desktop-setup.log -Append
$User = '${username}'
$Pass = '${password}'

# ---------------------------------------------------------------------------
# 1. The user's volume -> D:. A RAW disk is this user's first-ever Windows
#    session: initialise and format it. Anything already formatted is a
#    returning volume: assign the letter and touch nothing else. Formatting
#    is gated on RAW, so a returning volume can never be wiped from here.
# ---------------------------------------------------------------------------
Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Number -ne 0 } | ForEach-Object {
  Write-Output "initialising fresh data disk $($_.Number)"
  Initialize-Disk -Number $_.Number -PartitionStyle GPT -PassThru |
    New-Partition -DriveLetter D -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "UserData" -Confirm:$false | Out-Null
}
Get-Partition | Where-Object { $_.DiskNumber -ne 0 -and $_.Size -gt 1GB -and -not $_.DriveLetter -and $_.Type -ne 'Reserved' } |
  ForEach-Object { Write-Output "reattaching existing data disk"; $_ | Set-Partition -NewDriveLetter D }

$HasD = Test-Path "D:\"
if ($HasD) {
  foreach ($f in "Desktop", "Documents", "Downloads", "Pictures", "Profiles") {
    New-Item -ItemType Directory -Path "D:\$f" -Force | Out-Null
  }
  # Known folders for NEW profiles -> D:. The user's profile does not exist
  # yet (it is created from Default at first logon), so this is written into
  # the Default hive, which is exactly the moment it takes effect. Without
  # this, "Save" lands on C: and dies with the instance.
  reg load HKU\DefUser C:\Users\Default\NTUSER.DAT | Out-Null
  $usf = "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
  reg add "$usf" /v Desktop /t REG_EXPAND_SZ /d "D:\Desktop" /f | Out-Null
  reg add "$usf" /v Personal /t REG_EXPAND_SZ /d "D:\Documents" /f | Out-Null
  reg add "$usf" /v "{374DE290-123F-4565-9164-39C4925E467B}" /t REG_EXPAND_SZ /d "D:\Downloads" /f | Out-Null
  reg add "$usf" /v "My Pictures" /t REG_EXPAND_SZ /d "D:\Pictures" /f | Out-Null
  [gc]::Collect()
  reg unload HKU\DefUser | Out-Null
} else {
  # No volume this session (persist=false). The image points Chrome's
  # profile at D:; with no D: Chrome would refuse to start, so drop the
  # policy and let it use its default location on C:.
  Write-Output "no data disk - session is fully ephemeral"
  Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "UserDataDir" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 2. The desktop user. Password complexity is off in the image (see
#    bake-windows.ps1) so the workflow's hex password is accepted.
# ---------------------------------------------------------------------------
$sec = ConvertTo-SecureString $Pass -AsPlainText -Force
if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
  Set-LocalUser -Name $User -Password $sec
} else {
  New-LocalUser -Name $User -Password $sec -FullName $User -AccountNeverExpires -PasswordNeverExpires | Out-Null
  Add-LocalGroupMember -Group "Administrators" -Member $User
}

# Auto-logon keeps the console session signed in across any reboot. The
# DCV login itself is what signs the user in on first connect.
$wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $wl "AutoAdminLogon" "1"
Set-ItemProperty $wl "DefaultUserName" $User
Set-ItemProperty $wl "DefaultPassword" $Pass
Set-ItemProperty $wl "DefaultDomainName" $env:COMPUTERNAME
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DisableCAD" 1 -Type DWord

# ---------------------------------------------------------------------------
# 3. Hand DCV's console session to this user. SYSTEM hive, not HKLM.
# ---------------------------------------------------------------------------
$dcv = "Registry::HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv"
New-Item -Path "$dcv\session-management\automatic-console-session" -Force | Out-Null
Set-ItemProperty "$dcv\session-management\automatic-console-session" "owner" $User -Type String
Restart-Service dcvserver
Write-Output "desktop-setup complete for $User (D: present: $HasD)"
Stop-Transcript
</powershell>
```

- [ ] **Step 4: Wire `main.tf`**

AMI filter (`values = [var.gpu ? "gpu" : "cpu"]`) becomes:
```hcl
    values = [local.windows ? (var.gpu ? "windows-gpu" : "windows") : (var.gpu ? "gpu" : "cpu")]
```

In `resource "aws_instance" "desktop"`, `instance_type` becomes:
```hcl
  instance_type = local.windows ? var.instance_type_windows : (var.gpu ? var.instance_type_gpu : var.instance_type)
```

Replace the `user_data_base64 = base64gzip(templatefile(...))` expression (keep its comment) with:
```hcl
  # Windows: plain base64, not gzip - EC2Launch v2 does not reliably unpack
  # gzipped user-data, and the PowerShell script is a few KB. Linux keeps
  # base64gzip for the reason in the comment above.
  user_data_base64 = local.windows ? base64encode(templatefile("${path.module}/user-data.ps1.tpl", {
    username = local.windows_user
    password = local.web_password
    })) : base64gzip(templatefile("${path.module}/user-data.sh.tpl", {
    hostname                 = local.effective_hostname
    image                    = var.image
    timezone                 = var.timezone
    web_user                 = var.web_user
    web_password             = local.web_password
    encoder                  = var.gpu ? var.encoder_gpu : var.encoder
    gpu                      = var.gpu ? "true" : "false"
    framerate                = var.framerate
    video_bitrate_kbps       = var.video_bitrate_kbps
    congestion_control       = var.congestion_control ? "true" : "false"
    fresh                    = var.fresh ? "true" : "false"
    cloudflare_dns_api_token = var.cloudflare_dns_api_token
    access_enabled           = local.access_enabled ? "true" : "false"
    persist_enabled          = (var.username == "" || var.user_volume_id != "") ? "true" : "false"
  }))
```
(Keep the existing `persist_enabled` comment above that key.)

`root_block_device.volume_size` becomes:
```hcl
    volume_size           = local.windows ? var.root_volume_gb_windows : (var.gpu ? var.root_volume_gb_gpu : var.root_volume_gb)
```

Tags: change the merge to add `OS` only for per-user desktops (the owner's tag set stays byte-identical):
```hcl
  tags = merge(
    { Name = local.display },
    var.username != "" ? {
      Owner      = var.username
      OwnerEmail = var.owner_email
      Role       = var.is_guest ? "guest-desktop" : "user-desktop"
      OS         = var.os
    } : {},
  )
```
Add inside the resource, after `metadata_options`:
```hcl
  lifecycle {
    precondition {
      condition     = !local.windows || var.username != ""
      error_message = "os=windows requires a username. The owner's own desktop is Linux-only."
    }
  }
```

Security group: `https_open` count `local.access_enabled ? 0 : 1` → `local.proxied ? 0 : 1`; `https_cloudflare_only` for_each `local.access_enabled ? ... ` → `local.proxied ? ...`, and its description `"webtop UI via Caddy - Cloudflare edge only (Access enforced there)"` → `"desktop UI - Cloudflare edge only (proxied hostname)"`.

DNS trigger: `proxied = local.access_enabled ? "true" : "false"` → `proxied = local.proxied ? "true" : "false"`.

`outputs.tf`, append:
```hcl
output "login_user" {
  description = "Account name the user signs in with. Linux: the panel username. Windows: the same, truncated to the 20-character local-account limit."
  value       = local.windows ? local.windows_user : var.web_user
}
```

- [ ] **Step 5: Validate, and prove the Linux plan is unchanged**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
terraform -chdir=terraform fmt -check -diff terraform 2>/dev/null || terraform -chdir=terraform fmt
terraform -chdir=terraform validate
export CLOUDFLARE_API_TOKEN=$(cat ~/.config/cloudflare/token) AWS_DEFAULT_REGION=ap-south-1
terraform -chdir=terraform plan -input=false -no-color -lock=false \
  -var username=plancheck -var owner_email=plancheck@example.com \
  -var web_user=plancheck -var web_password_override=plancheckpassword \
  -var cloudflare_dns_api_token=x \
  | sed -E 's/\(known after apply\)/KAA/; /^Plan:/!{/^ *[+~-]? *(id|arn|.*_at) /d}' \
  > /tmp/claude-1000/-home-mn/55650e4a-fb0d-48ff-ab35-8e33e1fbb48d/scratchpad/plan-after.txt
diff /tmp/claude-1000/-home-mn/55650e4a-fb0d-48ff-ab35-8e33e1fbb48d/scratchpad/plan-baseline.txt \
     /tmp/claude-1000/-home-mn/55650e4a-fb0d-48ff-ab35-8e33e1fbb48d/scratchpad/plan-after.txt
```
Expected: `validate` succeeds; the diff is **empty except** the added `+ "OS" = "linux"` tag lines and the `login_user` output. Anything else is a regression — fix before continuing.

- [ ] **Step 6: Wait for the bake, then plan the Windows path**

```bash
gh run watch $(gh run list --workflow=bake-ami.yml --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
aws ec2 describe-images --region ap-south-1 --owners self --filters "Name=tag:Variant,Values=windows" \
  --query 'Images[].[ImageId,Name,State]' --output text
terraform -chdir=terraform plan -input=false -no-color -lock=false \
  -var os=windows -var username=plancheck -var owner_email=plancheck@example.com \
  -var web_user=plancheck -var web_password_override=plancheckpassword \
  -var cloudflare_dns_api_token=x \
  | grep -E 'instance_type|volume_size|"OS"|proxied|ami ' 
```
Expected: the bake run succeeds; one `available` image; plan shows `instance_type = "m6i.large"`, `volume_size = 50`, `"OS" = "windows"`, `proxied = "true"`, and the Windows `ami-` id. If the bake failed, read `gh run view --log-failed`, fix `scripts/bake-windows.ps1`, re-run Task 1 Step 6.

- [ ] **Step 7: Commit**

```bash
git add terraform/
git commit -m "feat(terraform): os=windows variant - DCV image, PowerShell user-data, proxied-only ingress

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: Workflows — `desktop-up.yml` and `desktop-wipe.yml`

**Files:**
- Modify: `.github/workflows/desktop-up.yml` (inputs block, `Guest-only setup` step, `terraform apply` env, `Tell desktop... ready` payload, summary)
- Modify: `.github/workflows/desktop-wipe.yml` (`Delete the volume` step)

**Interfaces:**
- Consumes: `TF_VAR_os`, `TF_VAR_instance_type_windows`, `output login_user` (Task 3).
- Produces: dispatch inputs `os`, `instance_type_windows`; `session-ready` payload field `login_user`.

- [ ] **Step 1: Inputs** — after the `use_spot` input add:

```yaml
      os:
        description: "linux (default) or windows. Windows boots the baked Server 2025 + DCV image on instance_type_windows, always behind a Cloudflare-proxied hostname, with the user's NTFS volume as D:. Admin-only from the panel; there is no policy here - the panel is the enforcement point."
        type: choice
        options: [linux, windows]
        default: linux
      instance_type_windows:
        description: "Instance type when os=windows. m6i.large (2 vCPU/8GB) is half the price of a 4-vCPU size because the Windows licence is per vCPU; set c7i.xlarge if video playback stutters."
        required: false
        default: "m6i.large"
```

- [ ] **Step 2: Volume role and size by OS** — in `Guest-only setup (volume, password)`, replace the `describe-volumes` filter and `create-volume` lines:

```bash
          # One volume per (user, OS): a Linux volume is ext4 carrying
          # containerd state, Windows needs NTFS - they cannot be shared.
          if [ "${{ inputs.os }}" = "windows" ]; then ROLE=desktop-guest-data-windows; SIZE=20; else ROLE=desktop-guest-data; SIZE=15; fi
          if [ "${{ inputs.persist }}" = "true" ]; then
            VOL_ID=$(aws ec2 describe-volumes \
              --filters "Name=tag:Owner,Values=$GUEST_USERNAME" "Name=tag:Role,Values=$ROLE" \
              --query 'Volumes[0].VolumeId' --output text)
            if [ "$VOL_ID" = "None" ] || [ -z "$VOL_ID" ]; then
              VOL_ID=$(aws ec2 create-volume \
                --region "$AWS_REGION" --availability-zone "$AWS_AZ" \
                --size "$SIZE" --volume-type gp3 --encrypted \
                --tag-specifications "ResourceType=volume,Tags=[{Key=Owner,Value=$GUEST_USERNAME},{Key=Role,Value=$ROLE},{Key=ManagedBy,Value=workflow}]" \
                --query VolumeId --output text)
              echo "created $ROLE volume $VOL_ID for $GUEST_USERNAME"
            else
              echo "reusing existing $ROLE volume $VOL_ID for $GUEST_USERNAME"
            fi
```
(Everything after — the password-on-tag logic — is unchanged.)

- [ ] **Step 3: TF_VARs** — in the `terraform apply` step `env:` add:

```yaml
          TF_VAR_os: ${{ inputs.os }}
          TF_VAR_instance_type_windows: ${{ inputs.instance_type_windows }}
```

- [ ] **Step 4: `login_user` in the callback** — in `Tell desktop.mnour.dev the guest session is ready`, after `INSTANCE_ID=$(...)` add `LOGIN_USER=$(terraform -chdir=terraform output -raw login_user)`, and change the `jq -n` to:

```bash
          PAYLOAD=$(jq -n \
            --arg username "${{ inputs.guest_username }}" \
            --arg url "$URL" \
            --arg password "$PASSWORD" \
            --arg owner_email "${{ inputs.owner_email }}" \
            --arg launched_at "$LAUNCHED_AT" \
            --arg login_user "$LOGIN_USER" \
            --arg os "${{ inputs.os }}" \
            '{username:$username, url:$url, password:$password, owner_email:$owner_email, launched_at:($launched_at|tonumber), login_user:$login_user, os:$os}')
```

- [ ] **Step 5: Summary** — in `Where it is, and what it costs` replace the `| Instance |` line:

```bash
            echo "| OS | \`${{ inputs.os }}\` |"
            echo "| Instance | \`${{ inputs.os == 'windows' && inputs.instance_type_windows || inputs.instance_type }}\` |"
```

- [ ] **Step 6: Wipe both roles** — in `desktop-wipe.yml` replace the body of `Delete the volume` from `read -r VOL ...` to the end with:

```bash
          DELETED=0
          # Both roles: "delete my data" means all of it. Same tag pair the
          # start workflow uses, so this can only match this user's desktop
          # data volumes - never the owner's, the hub's, or a root disk.
          for ROLE in desktop-guest-data desktop-guest-data-windows; do
            read -r VOL STATE ATTACHED <<<"$(aws ec2 describe-volumes \
              --filters "Name=tag:Owner,Values=$USER" "Name=tag:Role,Values=$ROLE" \
              --query 'Volumes[0].[VolumeId,State,Attachments[0].InstanceId]' --output text)"
            if [ "$VOL" = "None" ] || [ -z "$VOL" ]; then
              echo "no $ROLE volume for '$USER'"
              continue
            fi
            echo "$ROLE: $VOL state=$STATE attached_to=$ATTACHED"
            # Refuse while attached: deleting under a running desktop corrupts
            # whatever is mid-write, and AWS rejects it anyway.
            if [ "$STATE" != "available" ]; then
              echo "::error::Volume $VOL is '$STATE' (attached to ${ATTACHED:-unknown}). Destroy the desktop first."
              exit 1
            fi
            aws ec2 delete-volume --volume-id "$VOL"
            echo "deleted $VOL"
            DELETED=$((DELETED+1))
            sleep 3
            if aws ec2 describe-volumes --volume-ids "$VOL" >/dev/null 2>&1; then
              echo "::warning::$VOL still visible - deletion may still be settling."
            fi
          done
          if [ "$DELETED" -eq 0 ]; then
            echo "No saved data volumes for '$USER' - nothing to delete."
            echo "NOTHING_TO_DO=true" >> "$GITHUB_ENV"
            exit 0
          fi
```
Keep the existing `data-wiped` callback block after this loop; it posts once regardless of how many volumes went.

- [ ] **Step 7: Validate and commit**

```bash
for f in desktop-up desktop-wipe; do python3 -c "import yaml; yaml.safe_load(open('.github/workflows/$f.yml')); print('$f ok')"; done
git add .github/workflows/desktop-up.yml .github/workflows/desktop-wipe.yml
git commit -m "feat(workflows): os + instance_type_windows inputs, per-OS data volumes, login_user callback

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: Panel library helpers, test-first

**Files:**
- Modify: `panel/lib/desktops.js`
- Create: `panel/test/desktops.test.js`
- Modify: `panel/package.json`

**Interfaces:**
- Produces:
  - `HOURLY_USD_WINDOWS: number` (env `HOURLY_USD_WINDOWS`, default `0.103`)
  - `hourlyRate(os: string|undefined): number`
  - `requestedOs(isAdmin: boolean, bodyOs: unknown): "linux"|"windows"`
  - `probeUrl(url: string|null, os: string|undefined): string|null` — `<url>/healthz` for Linux, `<url>/` for Windows
  - `urlUp(probe: string|null, timeoutMs?): Promise<boolean>` — **now takes the full probe URL** (the only caller is `refreshOwn`, updated here)

- [ ] **Step 1: Write the failing tests**

`panel/test/desktops.test.js`:
```js
import test from "node:test";
import assert from "node:assert/strict";
import {
  hourlyRate, requestedOs, probeUrl, HOURLY_USD, HOURLY_USD_WINDOWS,
} from "../lib/desktops.js";

test("hourlyRate: linux and undefined use the CPU rate, windows its own", () => {
  assert.equal(hourlyRate("linux"), HOURLY_USD);
  assert.equal(hourlyRate(undefined), HOURLY_USD);
  assert.equal(hourlyRate("windows"), HOURLY_USD_WINDOWS);
  assert.ok(HOURLY_USD_WINDOWS > HOURLY_USD);
});

test("requestedOs: only an admin asking for windows gets windows", () => {
  assert.equal(requestedOs(true, "windows"), "windows");
  assert.equal(requestedOs(false, "windows"), "linux");
  assert.equal(requestedOs(true, "linux"), "linux");
  assert.equal(requestedOs(true, undefined), "linux");
  assert.equal(requestedOs(true, "WINDOWS"), "linux"); // exact match only
  assert.equal(requestedOs(true, { os: "windows" }), "linux");
});

test("probeUrl: /healthz for linux, DCV root for windows, null passes through", () => {
  assert.equal(probeUrl("https://a.desktop.example", "linux"), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", undefined), "https://a.desktop.example/healthz");
  assert.equal(probeUrl("https://a.desktop.example", "windows"), "https://a.desktop.example/");
  assert.equal(probeUrl(null, "windows"), null);
});
```

Add to `panel/package.json` (top level, after `"engines"`):
```json
  "scripts": { "test": "node --test test/" },
```

- [ ] **Step 2: Run, expect failure**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop/panel && npm test
```
Expected: FAIL — `hourlyRate`/`requestedOs`/`probeUrl`/`HOURLY_USD_WINDOWS` are not exported.

- [ ] **Step 3: Implement in `panel/lib/desktops.js`**

After the `HOURLY_USD` export add:
```js
// Windows on the same instance class is ~2x: the Windows licence is priced
// per vCPU and spot does not discount it. m6i.large (2 vCPU) Windows spot in
// ap-south-1, measured 2026-09-11. Keep in step with
// terraform/variables.tf instance_type_windows.
export const HOURLY_USD_WINDOWS = Number(process.env.HOURLY_USD_WINDOWS || 0.103);

export function hourlyRate(os) {
  return os === "windows" ? HOURLY_USD_WINDOWS : HOURLY_USD;
}

// The server-side policy for who may start Windows. The client only shows
// the selector to admins, but - as with persist - this is the enforcement
// point: anyone else asking for windows silently gets linux.
export function requestedOs(isAdmin, bodyOs) {
  return isAdmin === true && bodyOs === "windows" ? "windows" : "linux";
}

// What "the desktop answers" means per OS. Linux: Caddy serves /healthz.
// Windows: DCV serves its web client at / and has no health endpoint - a
// 200 there is the equivalent signal. Without this a Windows session would
// sit on "Booting..." forever after it was up.
export function probeUrl(url, os) {
  if (!url) return null;
  return os === "windows" ? `${url}/` : `${url}/healthz`;
}
```

Change `urlUp` to take the full probe URL:
```js
export async function urlUp(probe, timeoutMs = 2500) {
  if (!probe) return false;
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await fetch(probe, { signal: ac.signal });
    return r.status === 200;
  } catch {
    return false;
  } finally {
    clearTimeout(t);
  }
}
```
and in `refreshOwn` change `(await urlUp(s.url))` to `(await urlUp(probeUrl(s.url, s.os)))`.

- [ ] **Step 4: Run, expect pass**

```bash
npm test
```
Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
git add panel/lib/desktops.js panel/test/desktops.test.js panel/package.json
git commit -m "feat(panel): per-OS rate, os policy and readiness probe helpers, with tests

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: Panel API — dispatch, session-ready, status, admin list

**Files:**
- Modify: `panel/api/dispatch.js:6, 43-63`
- Modify: `panel/api/session-ready.js:26-36`
- Modify: `panel/api/status.js:6-8, 52-58`
- Modify: `panel/public/admin.js:22`

**Interfaces:**
- Consumes: `requestedOs`, `HOURLY_USD_WINDOWS` (Task 5); dispatch inputs `os` (Task 4); callback fields `login_user`, `os` (Task 4).
- Produces: session hash fields `os` (`"linux"|"windows"`), `login_user` (string|null); `/api/status` field `hourly_usd_windows`.

- [ ] **Step 1: `dispatch.js`** — import and use the policy:

```js
import { activeCount, MAX_CONCURRENT, requestedOs } from "../lib/desktops.js";
```
In the `start` branch, after `const persist = ...`:
```js
    // Windows is admin-only for now. Same shape as persist: the selector is
    // only rendered for admins, and this line is what actually enforces it.
    const os = requestedOs(session.is_admin, req.body?.os);
```
`putSession(me, { ... is_guest: !session.can_persist, os })`, `logEvent("login_start", { username: me, email: session.email, persist, os })`, and add `os,` to the `dispatch(workflow, {...})` inputs (inputs are strings; `os` already is).

- [ ] **Step 2: `session-ready.js`** — preserve `os`, store `login_user`:

```js
  const isGuest = Boolean(prior.is_guest);
  // os was decided at dispatch from a verified session; the callback's value
  // is only a fallback for a session with no prior state (redeploy mid-run).
  const os = prior.os || (req.body?.os === "windows" ? "windows" : "linux");
  await putSession(username, {
    status: "ready", // the page polls the per-OS probe before calling it active
    email,
    url: req.body?.url || null,
    password: req.body?.password || null,
    login_user: req.body?.login_user || null,
    started_at: startedAt,
    is_guest: isGuest,
    os,
    ...(isGuest ? { expires_at: startedAt + (await getGuestLimitMinutes()) * 60 } : {}),
  });
  await logEvent("start", { username, email, url: req.body?.url, os });
```

- [ ] **Step 3: `status.js`** — import `HOURLY_USD_WINDOWS` alongside `HOURLY_USD` and add to `out`:
```js
    hourly_usd_windows: HOURLY_USD_WINDOWS,
```

- [ ] **Step 4: `admin.js`** — line 22, show the OS:
```js
    row.innerHTML = `<div><strong>${esc(uname)}</strong><div class="who">${esc(sess.email || "")} &middot; ${esc(sess.status)} &middot; ${esc(sess.os || "linux")}</div></div>`;
```

- [ ] **Step 5: Syntax-check every touched module and run tests**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop/panel
for f in api/dispatch.js api/session-ready.js api/status.js; do node --check $f && echo "$f ok"; done
node --check public/admin.js && echo "admin.js ok"
npm test
```
Expected: all `ok`, tests pass.

- [ ] **Step 6: Commit**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
git add panel/api/dispatch.js panel/api/session-ready.js panel/api/status.js panel/public/admin.js
git commit -m "feat(panel): admin-only os on dispatch, os/login_user on sessions, per-OS rate in status

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: Panel UI — selector, Windows credentials card, per-OS open link and rate

**Files:**
- Modify: `panel/public/app.js:97-104, 113-146, 175-178, 258-263`

**Interfaces:**
- Consumes: `session.is_admin`, `my_session.os`, `my_session.login_user`, `hourly_usd_windows` (Task 6).

- [ ] **Step 1: Selector on the start card** — replace the `persistLabel` block and `box.innerHTML` (lines 98-104):

```js
    const persistLabel = session.can_persist
      ? `<label><input type="checkbox" id="persist"> Keep my files after destroy</label>`
      : "";
    // Admin-only for now (server-enforced in /api/dispatch). Everyone else
    // sees this card exactly as before: no hint that a second OS exists.
    const osSelect = session.is_admin
      ? `<label>Operating system <select id="os"><option value="linux">Linux</option><option value="windows">Windows</option></select></label>`
      : "";
    box.innerHTML = `
      ${osSelect}
      ${persistLabel}
      <div class="row"><button id="start" class="go">Start my desktop</button></div>
      ${dataBlock}`;
```

- [ ] **Step 2: Running card** — after `const running = ...` add `const isWin = mine.os === "windows";`; change the cost expression to use the per-OS rate:

```js
    const rate = isWin ? (s.hourly_usd_windows || 0.103) : (s.hourly_usd || 0.0529);
    html += ` <span class="sub">&middot; ${fmtDur(secs)} &middot; ~$${((secs / 3600) * rate).toFixed(2)} this session</span>`;
```
and the header line: `${running ? "Running" : "Booting&hellip;"}${isWin ? " &middot; Windows" : ""}`.

Replace the `openUrl` line and the credentials block with:
```js
  // Linux: Basic-Auth credentials ride in the URL (see loginUrl) so the link
  // logs straight in. Windows: DCV has its own sign-in page and ignores URL
  // credentials, so the link is plain and the card shows both fields.
  const openUrl = isWin ? mine.url : loginUrl(mine.url, session.user_id, mine.password);
  const loginUser = mine.login_user || session.user_id;
  html += `<div class="creds">
      ${isWin ? `<div><span class="ck">username</span><span class="cv">${esc(loginUser)}</span><button type="button" class="copy-btn" data-copy="${esc(loginUser)}" title="Copy username">&#128203;</button></div>` : ""}
      ${mine.password
        ? `<div><span class="ck">password</span><span class="cv">${esc(mine.password)}</span><button type="button" class="copy-btn" data-copy="${esc(mine.password)}" title="Copy password">&#128203;</button></div>
      <div class="sub" style="margin-top:.35rem">${isWin
        ? "Windows asks for these on its sign-in page. First start takes a little longer while your files drive is prepared."
        : "Opening the desktop below logs you straight in. Only copy this if it asks anyway, or you're opening it in a different browser."}</div>`
        : '<div class="sub">Password not recorded &mdash; this desktop was recovered rather than started normally.</div>'}
    </div>`;
```

- [ ] **Step 3: Send `os` on start** — in `go()`:
```js
  if (action === "start") {
    body.persist = $("persist")?.checked || false;
    body.os = $("os")?.value || "linux";
  }
```

- [ ] **Step 4: Auto-open uses the plain URL for Windows** — in `poll()` replace the `window.open(...)` line:
```js
      const target = s.my_session.os === "windows"
        ? s.my_session.url
        : loginUrl(s.my_session.url, session?.user_id, s.my_session.password);
      try { opened = window.open(target, "_blank", "noopener"); } catch { /* blocked */ }
```

- [ ] **Step 5: Style the select like the checkbox** — in `panel/public/index.html` next to `input[type=checkbox]{accent-color:var(--green)}` add:
```css
 select{background:#111;color:inherit;border:1px solid #333;border-radius:6px;padding:.3rem .5rem;margin-left:.4rem}
```

- [ ] **Step 6: Check and commit**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
node --check panel/public/app.js && echo ok
git add panel/public/app.js panel/public/index.html
git commit -m "feat(panel): admin-only OS selector, Windows sign-in card, per-OS cost and open link

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 8: Merge to `main` and confirm both halves are live

The panel deploys from `main` on Vercel; GitHub reads dispatched workflows from `main`. Nothing is testable from the panel until this lands.

**Files:** none.

- [ ] **Step 1: Push, open the PR, merge**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
git push
gh pr create --title "feat: Windows desktops (Server 2025 + DCV) as an admin-only variant" \
  --body "$(cat <<'EOF'
Implements docs/superpowers/specs/2026-09-11-windows-desktop-variant-design.md.

- bake-ami.yml: os=windows path, scripts/bake-windows.ps1, Variant=windows (baked in ap-south-1 from this branch)
- terraform: var.os, instance_type_windows, root_volume_gb_windows, PowerShell user-data, proxied-only ingress, OS tag, login_user output
- workflows: os + instance_type_windows inputs, per-OS data volumes, wipe both roles
- panel: admin-only selector, server-side policy, DCV readiness probe, Windows sign-in card, per-OS rate

Linux plan verified unchanged against a pre-change baseline (only the OS tag and login_user output differ).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --squash --delete-branch
git checkout main && git pull -q
```

- [ ] **Step 2: Confirm the panel deployed and the workflow on `main` has the input**

```bash
sleep 90
curl -s https://desktop.mnour.dev/api/status | python3 -c "import sys,json; d=json.load(sys.stdin); print('hourly_usd_windows' in d and 'panel deployed' or 'NOT YET - wait and retry')"
gh workflow view desktop-up.yml --yaml | grep -c "instance_type_windows"
```
Expected: `panel deployed`; count ≥ 1.

---

### Task 9: End-to-end from the panel as the admin

**Files:** none. Produces measured boot time and a verified persistence loop.

- [ ] **Step 1: Start Windows from the panel**

Signed in at `https://desktop.mnour.dev` as `mnuowr@gmail.com`: the **Operating system** selector is visible; pick **Windows**, tick **Keep my files after destroy**, Start. Note the wall-clock time. Meanwhile:
```bash
gh run watch $(gh run list --workflow=desktop-up.yml --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```
Expected: run succeeds; the `Guest-only setup` log says `created desktop-guest-data-windows volume`; `terraform apply` shows `m6i.large`.

- [ ] **Step 2: Readiness and access**

On the panel the card moves Booting → **Running · Windows** and shows **username** and **password**. Record the seconds from Start to Running. Click **Open desktop**: the URL is `https://mnuowr.desktop.mnour.dev/` (no port), **no certificate warning**, DCV's sign-in page. Sign in with the shown credentials. Expected: a Windows 11-style desktop, no Server Manager, Chrome/7-Zip/VLC present.

Also confirm the direct path is closed:
```bash
IP=$(aws ec2 describe-instances --region ap-south-1 --filters "Name=tag:Owner,Values=mnuowr" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
curl -sk --max-time 6 -o /dev/null -w "direct-ip http=%{http_code}\n" https://$IP/ || echo "direct-ip: refused (expected)"
```
Expected: timeout/refused — the security group is Cloudflare-only.

- [ ] **Step 3: Persistence markers**

Inside the desktop: Explorer shows **D:**; `Documents` and `Downloads` resolve to `D:\Documents`, `D:\Downloads`. Save a text file `D:\Documents\keep-me.txt` with the current time. In Chrome, bookmark any page. Confirm `D:\Profiles\Chrome\mnuowr` exists.

- [ ] **Step 4: Destroy, start again, verify**

Panel → **Destroy**. Wait for the card to return to Start (`gh run watch` on the down run). Start **Windows** again with persist ticked. Expected: `Guest-only setup` says `reusing existing desktop-guest-data-windows volume`; after sign-in `keep-me.txt` and the bookmark are present; user-data log on the box (`C:\desktop-setup.log`) says `reattaching existing data disk`. Record the second boot time.

- [ ] **Step 5: Non-admin cannot get Windows**

From a non-admin Google account (or an admin account temporarily removed from `admins` in the admin console): the selector is absent. Force the request:
```bash
# with a browser session cookie for the non-admin, from devtools console on desktop.mnour.dev:
# fetch("/api/dispatch",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"start",os:"windows"})})
```
Expected: the resulting run's `terraform apply` shows the Linux AMI and `c7i.xlarge`; the admin console lists the session as `linux`. Destroy it.

- [ ] **Step 6: Wipe deletes the Windows volume (owner-driven)**

Deleting a data volume is the owner's call, never the executor's. After Step 4's desktop is destroyed, ask the owner to click **Delete my saved data** on the panel (or skip if they want to keep the Windows volume for Task 10). If they do:
```bash
gh run watch $(gh run list --workflow=desktop-wipe.yml --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
aws ec2 describe-volumes --region ap-south-1 --filters "Name=tag:Owner,Values=mnuowr" \
  --query 'Volumes[].[VolumeId,Tags[?Key==`Role`]|[0].Value,State]' --output text
```
Expected: the run log shows `desktop-guest-data-windows: vol-... deleted`; the listing no longer contains a `desktop-guest-data-windows` volume for `mnuowr`; any `desktop-guest-data` (Linux) volume is untouched.

- [ ] **Step 7: Record results in the plan**

Append to this file under a `## Results` heading: boot #1 seconds, boot #2 seconds, direct-IP result, persistence result, wipe result (or "skipped by owner"). Commit:
```bash
git add docs/superpowers/plans/2026-09-11-windows-desktop-variant.md
git commit -m "docs(plan): Windows end-to-end results

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 10: The measurement — 2 vCPU vs 4 vCPU on video

**Files:**
- Modify: `terraform/variables.tf` (`instance_type_windows` default, only if the measurement says so), `.github/workflows/desktop-up.yml` (`instance_type_windows` default, same condition)

- [ ] **Step 1: Session A — `m6i.large`** (the one from Task 9 if still running, else start it). In the remote Chrome play a 1080p YouTube video full-window for two minutes. In the DCV web client open the toolbar → **Streaming mode / statistics** and record: frame rate, latency (ms), bandwidth. Note subjective smoothness and typing lag in Notepad while the video plays.

- [ ] **Step 2: Session B — `c7i.xlarge`**. Destroy A. Dispatch by hand with the larger size (the callback still lands in the panel):
```bash
gh workflow run desktop-up.yml -f os=windows -f instance_type_windows=c7i.xlarge \
  -f username=mnuowr -f guest_username=mnuowr -f owner_email=mnuowr@gmail.com -f persist=true -f is_guest=false
```
Repeat Step 1's measurement.

- [ ] **Step 3: Decide and record**

Rule from the spec: 2 vCPU holds ~30 fps with usable input latency → keep `m6i.large`; otherwise set both defaults to `c7i.xlarge` and `HOURLY_USD_WINDOWS` default in `panel/lib/desktops.js` to `0.204`. Append the two measurements to `## Results` in this plan. Destroy B. Commit whatever changed:
```bash
git add -A terraform/variables.tf .github/workflows/desktop-up.yml panel/lib/desktops.js docs/superpowers/plans/2026-09-11-windows-desktop-variant.md
git commit -m "chore(windows): instance size from measured video playback

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push
```

---

### Task 11: Docs, spec deviations, memory

**Files:**
- Modify: `README.md` (after the Live/Admin lines near the top, and a short "Windows" subsection where the Linux desktop is described)
- Modify: `docs/superpowers/specs/2026-09-11-windows-desktop-variant-design.md` (image section: MSIs not winget; no Windows Update pass; password complexity)
- Modify: `/home/mn/.claude/projects/-home-mn/memory/project_ephemeral_cloud_desktop.md` and `MEMORY.md` index line

- [ ] **Step 1: README** — add under the architecture description:

```markdown
### Windows desktops (admin-only)

`os=windows` boots a baked **Windows Server 2025** image (the Windows 11
24H2 shell) and streams it through **Amazon DCV** in the browser on 443.
The hostname is always Cloudflare-proxied, so there is no certificate
warning and the instance is unreachable by direct IP. The user's files live
on a separate NTFS volume mounted as `D:` (Desktop/Documents/Downloads/
Pictures and Chrome's profile are redirected there); the machine itself is
disposable. Windows 11 client itself cannot be licensed on shared EC2 -
see `docs/superpowers/specs/2026-09-11-windows-desktop-variant-design.md`.

Bake the image once per region: **Actions → Bake Desktop AMI → os=windows**.
Cost: `m6i.large` Windows spot ≈ $0.10/hr in Mumbai; the Windows licence is
per vCPU, which is why the 2-vCPU size is the default.
```

- [ ] **Step 2: Spec** — in "The image" replace the winget bullet with "Baked apps from vendor MSIs (winget does not run reliably as SYSTEM): Google Chrome, 7-Zip, VLC", replace the Windows Update bullet with "No update pass in the bake (AWS republishes the base monthly); automatic reboots disabled at runtime", and add a bullet "Local password-complexity policy off: stored passwords are 32 hex chars (two classes); the default policy demands three."

- [ ] **Step 3: Memory** — in `project_ephemeral_cloud_desktop.md` add a dated section: Windows variant live (date), how to use it (selector, admin-only), the DCV SYSTEM-hive rule, the `/healthz` vs `/` probe, per-OS volumes, the measured size decision, and the licensing conclusion (Server 2025, not Win11, and why). Update the `MEMORY.md` index line to mention Windows.

- [ ] **Step 4: Commit and push**

```bash
cd ~/Documents/Code/ephemeral-cloud-desktop
git add README.md docs/superpowers/specs/2026-09-11-windows-desktop-variant-design.md
git commit -m "docs: Windows desktop variant - README section and spec deviations

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push
git stash list   # remind: the PANEL_URL stash is still here for the sihaab.com work
```

---

## Results

End-to-end proven by the owner on 2026-09-12 at
`https://mnuowr-desktop.mnour.dev/` (Let's Encrypt certificate, direct):
Windows boots, logs in automatically, and DCV is reachable through Caddy on
443. Files saved to `D:\` root and to the redirected `Downloads` folder
survived a full destroy and restart of the instance — the per-user NTFS
volume attach/detach path holds.

**Boot times (Start click to DCV answering):**
- Fresh session (run 34688319766): 10:23:37Z → 10:26:43Z ≈ **3 min 6 s**.
- Restart of an existing volume (run 34693627568): 12:25:32Z → 12:28:41Z ≈
  **3 min 9 s**.

**Badge numbers (fps / input latency, 1080p video, `c7i.xlarge`, CPU idle):**
- Via Cloudflare proxy: **1 fps / 303 ms**.
- Direct (no proxy): **8 fps / 78 ms**.
- `m6i.large` (2 vCPU), direct: **4 fps / 296 ms**.

**Size decision:** `instance_type_windows` defaults to `c7i.xlarge` (4 vCPU),
not the originally-provisional `m6i.large` (2 vCPU) — the measurement above
showed 2 vCPU starves software H.264 encoding (4 fps vs. 8 fps at 4 vCPU),
so the ~2x cost is kept.

**Root causes hit, in order, with their PRs:**
1. **Registry `New-Item -Force` throws on a pre-existing key**
   ("Cannot delete a subkey tree because the subkey does not exist") — found
   via forensic read of `C:\bake-error.txt` off an attached root volume,
   fixed with an existence-guarded helper (Task 1 fix round 2/3, folded into
   PR #9).
2. **Sysprep breaks `dcvserver`** — a sysprepped image's DCV died loading
   display modules on first boot (bake `agent.log`:
   `Could not setup idd system pipeline 0x80070057`). Fixed by dropping
   sysprep (`EC2Launch.exe reset --clean` + `Stop-Computer`) and adding an
   AMI smoke test that launches the image and requires DCV to answer before
   trusting it (PR #12; a DCV-IDD-exclusion hypothesis tried in between did
   not fix it — PR #13).
3. **DCV refuses port 443** ("Invalid port 443, ignoring all endpoints" →
   "No HTTP listen endpoints set") — proven by an A/B test on the same
   image (443 fails, 8443 answers 200). Fixed by moving DCV to 8443 with a
   Cloudflare Origin Rule to that port (PR #14).
4. **Two-level hostname fails TLS** — free Cloudflare Universal SSL covers
   only `*.mnour.dev` (one label), not `mnuowr.desktop.mnour.dev`. Fixed by
   switching Windows hostnames to single-label,
   `<username>-desktop.mnour.dev` (PR #10).
5. **PowerShell parse error, `"$i:"` is a drive-qualified variable** — this
   silently prevented the entire per-launch script from running for three
   attempts in a row (`err.tmp` under
   `C:\Windows\system32\config\systemprofile\AppData\Local\Temp\EC2Launch*\`,
   read via SSM once IAM `create-role` turned out to work). Fixed as
   `$($i):` (PR #15).
6. **`$ErrorActionPreference = "Stop"` leaked out of a `try` block** —
   turned Caddy's normal stderr INFO logging into a fatal
   `NativeCommandError` that killed the setup script before Caddy's
   scheduled task was ever registered. Fixed live over SSM, then in the
   template (PR #19).
7. **Cloudflare proxying throttled DCV** (1 fps / 300 ms vs. 8 fps / 78 ms
   direct) — the reason Windows moved to the Caddy + Let's Encrypt + DNS-only
   pattern Linux already uses, instead of the design's Cloudflare-proxy plan
   (PR #17).

Supporting fixes along the way: an AMI smoke test that deregisters a broken
image automatically (PR #12); launch diagnostics written to
`D:\.desktop-diagnostics\<timestamp>\` on every exit path, since C: state is
lost on destroy (PR #11); the `desktop-ssm-diagnostics` IAM instance profile
attached to every Windows session, the actual remote-debugging channel that
replaced the serial console once writes to COM1 turned out not to reach
`get-console-output` (PR #18); and the 4-vCPU default itself (PR #16).

Task 9 (end-to-end verification) and Task 10 (size decision) are DONE per
the above. Task 11 (this documentation pass) is the only remaining item.
