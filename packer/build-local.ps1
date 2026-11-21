#Requires -Version 5.1
<#
.SYNOPSIS
  Build the image locally on Hyper-V (Packer source hyperv-iso).

.DESCRIPTION
  Needs Packer in PATH, Hyper-V, and admin rights or membership in the group
  Hyper-V Administrators. The VHDX is in output-hyperv\Virtual Hard Disks\.

  The script finds the IP address of the host on the Hyper-V switch and gives
  it to Packer: with several vEthernet adapters (WSL, VMware, ...) the Hyper-V
  plugin of Packer can pick the wrong one, and the installer in the VM then
  cannot load its autoinstall config.

  Windows Firewall must let the VM reach the Packer HTTP server (TCP
  8000-9000 on the switch adapter). A Block rule for packer-plugin-hyperv
  (made by the firewall dialog) stops the build at "Waiting for SSH".

.EXAMPLE
  .\build-local.ps1
.EXAMPLE
  .\build-local.ps1 -MemoryMB 4096 -PackerArgs '-on-error=abort'
#>
[CmdletBinding()]
param(
    [string]$Switch = 'Default Switch',
    [int]$MemoryMB = 4096,
    [int]$Cpus = 4,
    # More arguments for 'packer build', for example '-on-error=abort'.
    [string[]]$PackerArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packer = Get-Command packer -ErrorAction SilentlyContinue
if (-not $packer) { throw 'packer is not in PATH. See https://developer.hashicorp.com/packer/install' }

# .NET instead of Get-NetIPAddress: it needs no CIM.
$adapterName = "vEthernet ($Switch)"
$adapter = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.Name -eq $adapterName }
if (-not $adapter) { throw "No network adapter '$adapterName'. Is the Hyper-V switch '$Switch' there?" }
$httpIp = $adapter.GetIPProperties().UnicastAddresses |
    Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
    Select-Object -First 1 -ExpandProperty Address
if (-not $httpIp) { throw "The adapter '$adapterName' has no IPv4 address." }
Write-Host "Host IP on '$Switch': $httpIp"

# A random password for SSH during the build only; the build locks it.
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = -join ($bytes | ForEach-Object { $_.ToString('x2') })

# Each argument is one string, so PowerShell does not split '-only=a.b' at the dot.
$arguments = @(
    'build', '-only=hyperv-iso.build-vm', '-timestamp-ui',
    '-var', "build_password=$password",
    '-var', "http_ip=$httpIp",
    '-var', "hyperv_switch=$Switch",
    '-var', "memory_mb=$MemoryMB",
    '-var', "cpus=$Cpus"
) + $PackerArgs + @('.')

Push-Location $PSScriptRoot
try {
    & $packer.Source init .
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & $packer.Source @arguments
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
