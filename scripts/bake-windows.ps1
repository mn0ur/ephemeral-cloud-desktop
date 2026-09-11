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

# Everything important is echoed to COM1: EC2 exposes the serial port as
# "console output" (aws ec2 get-console-output), which is the ONLY channel
# readable from outside this box - it has no SSM role, no RDP, no key pair.
# Without this a stalled bake is a black box (run 34574511394, 2026-09-11).
function Write-Console([string]$Message) {
  $line = "BAKE $(Get-Date -Format HH:mm:ss) $Message"
  Write-Output $line
  try {
    $port = New-Object System.IO.Ports.SerialPort "COM1", 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $port.Open(); $port.WriteLine($line); $port.Close()
  } catch { Write-Output "console write failed: $_" }
}

function Get-File($Url, $Out) {
  Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
}
function Install-Msi($Path) {
  $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$Path`" /quiet /norestart"
  if ($p.ExitCode -notin 0, 3010) { throw "msiexec $Path exited $($p.ExitCode)" }
}

try {
  # ---------------------------------------------------------------------------
  # 1. Amazon DCV. Free on EC2 (no licence server). Settings go in the SYSTEM
  #    hive - dcvserver never reads HKLM, and writing there looks correct while
  #    doing nothing (found the hard way in the 2026-09-11 spike).
  # ---------------------------------------------------------------------------
  Write-Console "phase: dcv download"
  Get-File "https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-server-x64-Release.msi" C:\dcv.msi
  Write-Console "phase: dcv install"
  Install-Msi C:\dcv.msi
  Write-Console "phase: dcv config"
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
  Write-Console "phase: desktop feel"
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
  Write-Console "phase: password policy"
  secedit /export /cfg C:\secpol.cfg | Out-Null
  (Get-Content C:\secpol.cfg) -replace 'PasswordComplexity = 1', 'PasswordComplexity = 0' | Set-Content C:\secpol.cfg
  secedit /configure /db C:\Windows\security\local.sdb /cfg C:\secpol.cfg /areas SECURITYPOLICY | Out-Null
  Remove-Item C:\secpol.cfg -Force

  # ---------------------------------------------------------------------------
  # 3. Baked apps. Vendor MSIs, not winget: winget is a per-user MSIX app and
  #    does not run reliably as SYSTEM. This list is "apps persist" for v1.
  # ---------------------------------------------------------------------------
  Write-Console "phase: chrome"
  Get-File "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" C:\chrome.msi
  Install-Msi C:\chrome.msi
  # Profile on the user's persistent volume, so bookmarks and logins survive
  # the instance. ${user_name} is expanded by Chrome, not by us. user-data
  # removes this policy on a session that has no D: (persist=false), otherwise
  # Chrome would refuse to start.
  New-Item -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Force | Out-Null
  Set-ItemProperty "HKLM:\SOFTWARE\Policies\Google\Chrome" "UserDataDir" 'D:\Profiles\Chrome\${user_name}' -Type String

  Write-Console "phase: 7zip"
  Get-File "https://www.7-zip.org/a/7z2409-x64.msi" C:\7z.msi
  Install-Msi C:\7z.msi

  Write-Console "phase: vlc"
  try {
    $idx = (Invoke-WebRequest "https://download.videolan.org/pub/videolan/vlc/last/win64/" -UseBasicParsing).Content
    $m = [regex]::Match($idx, 'vlc-[\d\.]+-win64\.msi')
    if ($m.Success) {
      Get-File "https://download.videolan.org/pub/videolan/vlc/last/win64/$($m.Value)" C:\vlc.msi
      Install-Msi C:\vlc.msi
    } else { Write-Output "VLC: no msi in index, skipped" }
  } catch { Write-Output "VLC skipped: $_" }   # a bake must not fail for VLC

  Write-Console "phase: cleanup"
  Remove-Item C:\*.msi -Force -ErrorAction SilentlyContinue

  Write-Console "BAKE-COMPLETE"
} catch {
  Write-Console "BAKE-FAILED: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
  "$($_.Exception.Message)`n$($_.ScriptStackTrace)" | Set-Content C:\bake-error.txt
  Stop-Transcript
  Stop-Computer -Force
  exit 1
}

# ---------------------------------------------------------------------------
# 4. Sysprep + shutdown. Without sysprep every launch would clone this
#    machine's identity and EC2Launch would not run user-data on first boot.
# ---------------------------------------------------------------------------
Write-Console "phase: sysprep"
Stop-Transcript
& "$env:ProgramFiles\Amazon\EC2Launch\EC2Launch.exe" sysprep --shutdown=true
</powershell>
