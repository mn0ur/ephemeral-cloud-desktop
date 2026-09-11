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
Ensure-RegKey "$dcv\session-management\automatic-console-session"
Set-ItemProperty "$dcv\session-management\automatic-console-session" "owner" $User -Type String
# DCV may still be in start-pending this early in boot. Retry, and make a
# failure unmistakable in the transcript - without an owner the console
# session cannot be logged into and the desktop looks up but is unusable.
$restarted = $false
for ($i = 1; $i -le 5 -and -not $restarted; $i++) {
  try { Restart-Service dcvserver -ErrorAction Stop; $restarted = $true }
  catch { Write-Output "dcvserver restart attempt $i failed: $($_.Exception.Message)"; Start-Sleep -Seconds 10 }
}
if (-not $restarted) { Write-Output "DESKTOP-SETUP-FAILED: dcvserver did not restart; console session owner not applied" }
if ($restarted) { Write-Output "desktop-setup complete for $User (D: present: $HasD)" }
Stop-Transcript
</powershell>
