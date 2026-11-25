<#
.SYNOPSIS
  Install usbip-stream.ps1 for Vibepollo and print the prep commands to add.

.DESCRIPTION
  Run from this repo in an Administrator PowerShell:

    powershell -ExecutionPolicy Bypass -File client\windows\install.ps1
    powershell -ExecutionPolicy Bypass -File client\windows\install.ps1 -Server 192.168.1.117
    powershell -ExecutionPolicy Bypass -File client\windows\install.ps1 -Uninstall

  It copies the script to C:\ProgramData\pi-setup, checks that usbip-win2 is
  installed and that the Pi answers, and prints the "do" and "undo" commands to
  paste into Vibepollo. Nothing is changed in Vibepollo itself.
#>
[CmdletBinding()]
param(
  [string]$Server = 'pilab-living',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramData 'pi-setup'
$script = Join-Path $dest 'usbip-stream.ps1'
$usbip = Join-Path $env:ProgramFiles 'USBip\usbip.exe'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this from an Administrator PowerShell.' }

if ($Uninstall) {
  if (Test-Path $script) { Remove-Item $script -Force }
  Write-Host "Removed $script. Also delete the usbip-stream commands from Vibepollo's Command Preparations."
  exit 0
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'usbip-stream.ps1') $script
Write-Host "Installed $script"

if (Test-Path $usbip) {
  Write-Host "Found usbip-win2 at $usbip"
  Write-Host "Devices $Server exports right now:"
  & $usbip list -r $Server
  if ($LASTEXITCODE -ne 0) { Write-Warning "$Server did not answer. Check the name, or use -Server <IP address>." }
} else {
  Write-Warning "usbip-win2 is not installed ($usbip is missing). Install it from https://github.com/vadimgrn/usbip-win2/releases first."
}

$arg = if ($Server -ne 'pilab-living') { " -Server $Server" } else { '' }
$base = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
Write-Host ''
Write-Host 'In Vibepollo: Configuration > General > Command Preparations > Add, then:'
Write-Host "  Do command:    $base attach$arg"
Write-Host "  Undo command:  $base detach$arg"
Write-Host '  Tick "Run as administrator" (elevated), then Save and Apply.'
