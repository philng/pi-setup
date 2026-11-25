<#
.SYNOPSIS
  Attach the USB devices a Raspberry Pi exports over USB/IP while a game stream runs.

.DESCRIPTION
  Meant for Vibepollo's (or Apollo/Sunshine's) "Command Preparations":

    do:    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\pi-setup\usbip-stream.ps1" attach
    undo:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\pi-setup\usbip-stream.ps1" detach

  with "Run as administrator" (elevated) ticked.

  attach  attaches every device the Pi exports. The Pi only exports the dongles
          you chose, and a device that is attached somewhere drops off its export
          list, so "attach whatever is exportable" is all it takes. If the Pi
          doesn't answer yet (the PC just woke up), it keeps trying for
          -TimeoutSeconds. Once attached, the usbip-win2 driver re-attaches a
          device on its own if the link drops mid-stream (Pi reboot, Wi-Fi blip).
  detach  stops any pending attach attempts and detaches every USB/IP device,
          handing the dongles back to the Pi.

  It always exits 0: a failing "do" command would stop the stream from
  starting, and a stream without the dongles is better than no stream.
  Everything is logged to C:\ProgramData\pi-setup\usbip-stream.log.

.EXAMPLE
  .\usbip-stream.ps1 attach -Server 192.168.1.117
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('attach', 'detach')]
  [string]$Action,

  # The Pi's name or IP address.
  [string]$Server = $(if ($env:USBIP_SERVER) { $env:USBIP_SERVER } else { 'pilab-living' }),

  # How long attach keeps retrying while the Pi or the network isn't up yet.
  [int]$TimeoutSeconds = 20,

  [string]$UsbipExe = $(if ($env:USBIP_EXE) { $env:USBIP_EXE } else { Join-Path $env:ProgramFiles 'USBip\usbip.exe' }),

  [string]$LogFile = $(if ($env:USBIP_STREAM_LOG) { $env:USBIP_STREAM_LOG } else { Join-Path $env:ProgramData 'pi-setup\usbip-stream.log' })
)

$ErrorActionPreference = 'Continue'

function Write-Log([string]$Message) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} {1} {2}' -f (Get-Date), $Action, $Message
  Write-Output $line
  try {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Keep the log small: start over once it passes 1 MB.
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Remove-Item $LogFile -Force }
    Add-Content -Path $LogFile -Value $line
  } catch { }
}

function Invoke-Usbip([string[]]$Arguments) {
  $out = & $UsbipExe @Arguments 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = @($out) }
}

# Bus IDs from `usbip list -r`. Lines look like
#   "      1-1.3: Valve Software : unknown product (28de:1142)"
function Get-Exportable {
  $r = Invoke-Usbip @('list', '-r', $Server)
  if (-not $r.Ok) { return $null }
  , @($r.Output | ForEach-Object { if ($_ -match '^\s+(\d+-[\d.]+):\s') { $Matches[1] } })
}

function Invoke-Attach {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $attached = 0
  while ($true) {
    $busids = Get-Exportable
    if ($null -ne $busids) {
      if ($busids.Count -eq 0) {
        if ($attached -eq 0) { Write-Log "nothing to attach: $Server exports no free devices (already attached, or none plugged in)" }
        return
      }
      $failed = 0
      foreach ($busid in $busids) {
        $r = Invoke-Usbip @('attach', '-r', $Server, '-b', $busid)
        if ($r.Ok) { $attached++; Write-Log "attached ${Server}:$busid" }
        else { $failed++; Write-Log "could not attach ${Server}:$busid ($($r.Output -join ' '))" }
      }
      if ($failed -eq 0) { return }
    } else {
      Write-Log "$Server is not answering yet"
    }
    if ((Get-Date) -ge $deadline) {
      Write-Log "gave up after $TimeoutSeconds s; the stream starts without the missing devices"
      return
    }
    Start-Sleep -Seconds 2
  }
}

function Invoke-Detach {
  # Pending background attach attempts would grab the dongles again.
  $null = Invoke-Usbip @('attach', '--stop-all')
  $r = Invoke-Usbip @('detach', '--all')
  if ($r.Ok) { Write-Log 'detached all USB/IP devices' }
  else { Write-Log "detach failed ($($r.Output -join ' '))" }
}

if (-not (Test-Path $UsbipExe)) {
  Write-Log "usbip.exe not found at $UsbipExe; install usbip-win2 (see docs/03-client.md)"
  exit 0
}

try {
  if ($Action -eq 'attach') { Invoke-Attach } else { Invoke-Detach }
} catch {
  Write-Log "error: $_"
}
exit 0
