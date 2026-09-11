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
    Write-Output "dcvserver status after attempt $i: $((Get-Service dcvserver -ErrorAction SilentlyContinue).Status)"
    Start-Sleep -Seconds 15
  }
}
if (-not $restarted) { Write-Output "DESKTOP-SETUP-FAILED: dcvserver did not start; console session owner not applied" }
if ($restarted) { Write-Output "desktop-setup complete for $User (D: present: $HasD)" }
if ($restarted) { Save-Diagnostics "ok" } else { Save-Diagnostics "dcv-start-failed" }
</powershell>
