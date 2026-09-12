<powershell>
# Per-launch setup for a Windows desktop. Runs once, as SYSTEM, on first boot
# of a sysprepped image (terraform/../scripts/bake-windows.ps1). Everything
# user-specific lives here; everything shared lives in the image.
#
# Terraform templatefile: only "$${" is escaped; plain "$Var" is PowerShell.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
Start-Transcript -Path C:\desktop-setup.log -Append

# New-Item -Force on a registry key that ALREADY exists throws "Cannot delete a
# subkey tree because the subkey does not exist" (PowerShell registry-provider
# quirk). The DCV console-session key exists from the image bake, so this
# would fail on every launch. Create only when absent.
function Ensure-RegKey([string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
}

# Every exit path leaves its evidence on the user's volume. C: dies with the
# instance and there is no SSM/RDP/key pair, so D: is the only place a
# failed launch can be diagnosed from (the first real Windows start failed in
# the DCV start step and left nothing readable, 2026-09-11).
function Save-Diagnostics([string]$Reason) {
  if (-not (Test-Path "D:\")) { return }
  try {
    $dir = "D:\.desktop-diagnostics\$(Get-Date -Format yyyyMMdd-HHmmss)-$Reason"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try { Stop-Transcript | Out-Null } catch {}
    Copy-Item C:\desktop-setup.log "$dir\desktop-setup.log" -ErrorAction SilentlyContinue
    Copy-Item C:\ProgramData\NICE\dcv\log\*.log $dir -ErrorAction SilentlyContinue
    Get-Service dcvserver -ErrorAction SilentlyContinue | Format-List * | Out-File "$dir\dcvserver-service.txt"
    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'} -MaxEvents 40 -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'dcv' } | Format-List TimeCreated, Id, Message | Out-File "$dir\scm-dcv-events.txt"
    Get-WinEvent -LogName Application -MaxEvents 60 -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -match 'dcv' -or $_.Message -match 'dcv' } | Format-List TimeCreated, ProviderName, Id, Message | Out-File "$dir\application-dcv-events.txt"
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess | Out-File "$dir\listeners.txt"
    (Invoke-RestMethod -Method PUT -Uri 'http://169.254.169.254/latest/api/token' -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='60'} -TimeoutSec 5 -ErrorAction SilentlyContinue) | Out-File "$dir\imdsv2-token-ok.txt"
  } catch { "diagnostics failed: $($_.Exception.Message)" | Out-File "D:\.desktop-diagnostics-error.txt" -Append }
}
$User = '${username}'
$Pass = '${password}'
$Hostname = '${hostname}'
$CfToken = '${cloudflare_dns_api_token}'

try {
  # $ErrorActionPreference = "Stop" INSIDE the try only: the file-level
  # "Continue" default stays as-is so the transcript setup above it can
  # never throw and abort before a single line is logged.
  $ErrorActionPreference = "Stop"

  # ---------------------------------------------------------------------------
  # 1. The user's volume -> D:. A RAW disk is this user's first-ever Windows
  #    session: initialise and format it. Anything already formatted is a
  #    returning volume: assign the letter and touch nothing else. Formatting
  #    is gated on RAW, so a returning volume can never be wiped from here.
  # ---------------------------------------------------------------------------
  Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Number -ne 0 } | ForEach-Object {
    Write-Output "initialising fresh data disk $($_.Number)"
    Initialize-Disk -Number $_.Number -PartitionStyle GPT -PassThru |
      New-Partition -AssignDriveLetter -UseMaximumSize |
      Format-Volume -FileSystem NTFS -NewFileSystemLabel "UserData" -Confirm:$false | Out-Null
  }

  # Find our volume by its label wherever Windows put it, and move it to D:.
  # Windows auto-assigns the next free letter to a returning NTFS volume, and
  # D: is often already taken (the EC2 DVD device) - assuming D: is free left
  # a real launch with no D:\ at all (2026-09-11), so the folder redirection
  # and the diagnostics silently did nothing.
  $vol = Get-Volume -FileSystemLabel "UserData" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($vol) {
    if ($vol.DriveLetter -ne 'D') {
      $taken = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
      if ($taken) {
        # Evict whatever holds D: (a DVD device, typically) to the next free letter.
        $free = [char[]](69..90) | Where-Object { -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
        Get-Partition -DriveLetter D -ErrorAction SilentlyContinue | Set-Partition -NewDriveLetter $free -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Volume -Filter "DriveLetter='D:'" -ErrorAction SilentlyContinue | Set-CimInstance -Property @{DriveLetter="$($free):"} -ErrorAction SilentlyContinue
      }
      $vol | Get-Partition | Set-Partition -NewDriveLetter D
      Write-Output "data volume moved from $($vol.DriveLetter): to D:"
    } else { Write-Output "data volume already at D:" }
  } else { Write-Output "no UserData volume found (fully ephemeral session, or first-boot format failed)" }

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
  Ensure-RegKey "$dcv\session-management\automatic-console-session"
  Set-ItemProperty "$dcv\session-management\automatic-console-session" "owner" $User -Type String
} catch {
  $msg = "$(Get-Date -Format o) $($_.Exception.Message)`n$($_.ScriptStackTrace)"
  Set-Content -Path C:\desktop-setup-FAILED.txt -Value $msg
  if (Test-Path D:\) { Set-Content -Path D:\desktop-setup-FAILED.txt -Value $msg }
  Write-Output "DESKTOP-SETUP-FAILED: $($_.Exception.Message)"
  try { Stop-Transcript } catch {}
  Save-Diagnostics "exception"
  exit 1
}

# ---------------------------------------------------------------------------
# 4. Hand off DCV from Manual (set in the image, see bake-windows.ps1) to
#    Automatic and start it. The image ships it Manual/stopped so the panel's
#    "443 answers" readiness probe cannot fire before sections 1-3 above have
#    created the account and set the console-session owner; only once that
#    has succeeded (the try/catch above did not exit 1) is it safe to bring
#    the port up.
# ---------------------------------------------------------------------------
# Back to "Continue" explicitly: the "Stop" set inside the try above is a
# global preference and OUTLIVES the try block. Left at Stop, the first native
# command that writes to stderr - caddy.exe logs INFO lines there - becomes a
# terminating error and the script dies silently before Caddy is scheduled
# (2026-09-12, session i-0d4ba144319e522c3).
$ErrorActionPreference = "Continue"
Set-Service dcvserver -StartupType Automatic
# DCV may still be in start-pending this early in boot. Retry, and make a
# failure unmistakable in the transcript - without the service actually
# running the console session cannot be logged into and the desktop looks
# up but is unusable.
$restarted = $false
for ($i = 1; $i -le 8 -and -not $restarted; $i++) {
  try { Start-Service dcvserver -ErrorAction Stop; $restarted = $true }
  catch {
    Write-Output "dcvserver start attempt $i failed: $($_.Exception.Message)"
    Write-Output "dcvserver status after attempt $($i): $((Get-Service dcvserver -ErrorAction SilentlyContinue).Status)"
    Start-Sleep -Seconds 15
  }
}
if (-not $restarted) { Write-Output "DESKTOP-SETUP-FAILED: dcvserver did not start; console session owner not applied" }
if ($restarted) { Write-Output "desktop-setup complete for $User (D: present: $HasD)" }
# ---------------------------------------------------------------------------
# 5. Caddy on 443 in front of DCV (127.0.0.1:8443), with a Let's Encrypt
#    certificate from the Cloudflare DNS-01 challenge - the Linux desktop's
#    exact arrangement. No Cloudflare proxy in the streaming path: through
#    the proxy DCV managed 1 fps / 300 ms, direct it did 8 fps / 78 ms.
#    Certificates are stored on D: when it exists, so a user's restarts reuse
#    the certificate instead of spending Let's Encrypt's 5-per-week
#    duplicate limit. Runs as a SYSTEM scheduled task (Caddy is not an SCM
#    service on Windows); "onstart" keeps it alive across any reboot.
# ---------------------------------------------------------------------------
if ($restarted -and $CfToken -ne '') {
  $storage = if (Test-Path "D:\") { "D:\caddy" } else { "C:\caddy\data" }
  New-Item -ItemType Directory -Path $storage -Force | Out-Null
  @"
{
  email admin@$Hostname
  storage file_system {
    root $storage
  }
}
$Hostname {
  tls {
    dns cloudflare $CfToken
  }
  reverse_proxy https://127.0.0.1:8443 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}
"@ | Set-Content -Path C:\caddy\Caddyfile -Encoding ASCII
  # Never pipe caddy's stderr into PowerShell error records - redirect to files.
  $v = Start-Process C:\caddy\caddy.exe -ArgumentList "validate --config C:\caddy\Caddyfile" -Wait -PassThru -RedirectStandardOutput C:\caddy\validate-out.txt -RedirectStandardError C:\caddy\validate-err.txt
  Write-Output "caddy validate exit code $($v.ExitCode)"
  schtasks /create /f /tn caddy /sc onstart /ru SYSTEM /rl HIGHEST /tr "C:\caddy\caddy.exe run --config C:\caddy\Caddyfile" | Out-Null
  schtasks /run /tn caddy | Out-Null
  Write-Output "caddy started for $Hostname (certificate storage: $storage)"
} elseif ($restarted) {
  Write-Output "no Cloudflare DNS token - caddy not started; DCV reachable on 8443 only"
}
if ($restarted) { Save-Diagnostics "ok" } else { Save-Diagnostics "dcv-start-failed" }
</powershell>
