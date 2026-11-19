# Add first-boot settings to a freshly flashed Raspberry Pi OS boot partition (Windows).
#
#   powershell -ExecutionPolicy Bypass -File scripts\configure-boot.ps1 E:\
#   powershell -ExecutionPolicy Bypass -File scripts\configure-boot.ps1 -Hostname octopi E:\
#
# Flash the card/SSD with Raspberry Pi Imager first (no customisation needed).
# Windows then shows the small "bootfs" partition as a drive letter; pass it here.
# It only writes a few small text files there and needs no admin rights.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param(
    [Parameter(Mandatory = $true)][string]$Boot,
    [string]$SshPubKeyFile,
    [string]$Hostname
)
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

# --- Read bootstrap/pi.env (simple KEY=VALUE lines) -------------------------
$cfg = @{}
foreach ($line in Get-Content (Join-Path $RepoRoot 'bootstrap/pi.env')) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') {
        $key = $Matches[1]; $val = $Matches[2].Trim()
        # Shell-style ${VAR:-default}: take the environment variable, else the default.
        if ($val -match '^\$\{([A-Z_]+):-(.*)\}$') {
            $envVal = [Environment]::GetEnvironmentVariable($Matches[1])
            $val = if ($envVal) { $envVal } else { $Matches[2] }
        }
        $cfg[$key] = $val
    }
}
if ($Hostname) { $cfg['PI_HOSTNAME'] = $Hostname }
# The login user comes from Ansible's settings, so the two can't disagree.
$groupVars = Join-Path $RepoRoot 'ansible/inventory/group_vars/pis.yml'
$userLine = Get-Content $groupVars | Where-Object { $_ -match '^ansible_user:\s*(\S+)' } | Select-Object -First 1
if (-not $userLine) { throw "no ansible_user in $groupVars" }
$null = $userLine -match '^ansible_user:\s*(\S+)'
$cfg['PI_USER'] = $Matches[1].Trim('"', "'")
if ($cfg['PI_HOSTNAME'] -cnotmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$') {
    throw "'$($cfg['PI_HOSTNAME'])' isn't a valid hostname: use lowercase letters, digits and dashes"
}
$inv = Get-Content (Join-Path $RepoRoot 'ansible/inventory/hosts.yml')
if (-not ($inv | Where-Object { $_ -cmatch "^ {12}$([regex]::Escape($cfg['PI_HOSTNAME'])):\s*$" })) {
    Write-Warning "$($cfg['PI_HOSTNAME']) is not in ansible/inventory/hosts.yml, so Ansible won't configure it. Add it under usbip or printers there."
}
if (-not $SshPubKeyFile) {
    $SshPubKeyFile = if ($env:SSH_PUBKEY_FILE) { $env:SSH_PUBKEY_FILE } `
                     else { Join-Path $HOME '.ssh\id_ed25519.pub' }
}

# --- Check the target -------------------------------------------------------
if (-not (Test-Path -LiteralPath $Boot -PathType Container)) { throw "$Boot is not a folder or drive" }
if (-not ((Test-Path (Join-Path $Boot 'config.txt')) -and (Test-Path (Join-Path $Boot 'cmdline.txt')))) {
    throw "$Boot doesn't look like a Raspberry Pi boot partition (no config.txt/cmdline.txt)"
}
if (-not (Test-Path -LiteralPath $SshPubKeyFile)) {
    throw "SSH public key not found: $SshPubKeyFile (pass -SshPubKeyFile or create one with ssh-keygen -t ed25519)"
}
$pubkey = (Get-Content -LiteralPath $SshPubKeyFile -TotalCount 1).Trim()

# Keep whatever Imager wrote, in case you want to compare.
foreach ($f in 'user-data', 'network-config') {
    $p = Join-Path $Boot $f
    if ((Test-Path $p) -and -not (Test-Path "$p.orig")) { Copy-Item $p "$p.orig" }
}

# --- Render and write (UTF-8 without BOM, LF line endings: cloud-init needs both)
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Unix([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
}

$tmpl = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'bootstrap/cloud-init/user-data.tmpl'))
$userData = $tmpl
$userData = $userData.Replace('@PI_HOSTNAME@', $cfg['PI_HOSTNAME'])
$userData = $userData.Replace('@PI_USER@', $cfg['PI_USER'])
$userData = $userData.Replace('@PI_TIMEZONE@', $cfg['PI_TIMEZONE'])
$userData = $userData.Replace('@PI_KEYBOARD@', $cfg['PI_KEYBOARD'])
$userData = $userData.Replace('@SSH_PUBKEY@', $pubkey)
if (-not $userData.StartsWith('#cloud-config')) { throw 'user-data render failed' }
Write-Unix (Join-Path $Boot 'user-data') $userData

$net = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'bootstrap/cloud-init/network-config'))
Write-Unix (Join-Path $Boot 'network-config') $net

$meta = Join-Path $Boot 'meta-data'
if (-not (Test-Path $meta)) { Write-Unix $meta "instance-id: $($cfg['PI_HOSTNAME'])`n" }

Write-Host "Wrote user-data and network-config to $Boot"
Write-Host "  hostname=$($cfg['PI_HOSTNAME']) user=$($cfg['PI_USER']) key=$SshPubKeyFile"
Write-Host 'Eject the drive, put it in the Pi, connect Ethernet and power on.'
