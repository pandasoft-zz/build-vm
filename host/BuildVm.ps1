#Requires -Version 7.4
<#
.SYNOPSIS
  Run the build-vm runner VM on Hyper-V: install, start, stop, register runners.

.DESCRIPTION
  One script for the whole life of the runner VM:

    Install     Download the image (GitHub release), create the VM, start it.
    Register    Add a runner for each repository and set the RUNNER variable.
    Unregister  Remove the runners and the RUNNER variable.
    Enable      Set the RUNNER variable only (jobs go to the VM).
    Disable     Remove the RUNNER variable only (jobs go to GitHub-hosted runners).
    Start       Start the VM and wait until it is ready.
    Stop        Shut the VM down.
    Status      Show the VM, the runners and the RUNNER variable of each repository.
    Ssh         Open an SSH session to the VM.
    Update      Unregister, remove the VM, install a new image, register again.
    Remove      Unregister and delete the VM with its files.

  Needs: Hyper-V, PowerShell 7.4+, an admin shell, the GitHub CLI `gh` logged in
  (`gh auth login`) with admin rights on the repositories, and the OpenSSH client
  (part of Windows).

.PARAMETER Command
  What to do (see the list above).

.PARAMETER Repo
  Repositories (OWNER/REPO). Default: Repos from the config file.

.PARAMETER Version
  Image release tag for Install and Update, for example v1.0.0. Default: latest.

.PARAMETER ConfigPath
  Config file. Default: buildvm.config.psd1 next to this script, or the
  example config when it does not exist.

.PARAMETER Force
  Do not ask before Remove and Update.

.EXAMPLE
  .\BuildVm.ps1 Install
  .\BuildVm.ps1 Register
  .\BuildVm.ps1 Status
  .\BuildVm.ps1 Disable -Repo owner/repo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Install', 'Register', 'Unregister', 'Enable', 'Disable', 'Start', 'Stop',
        'Status', 'Ssh', 'Update', 'Remove')]
    [string]$Command,

    [string[]]$Repo,

    [string]$Version = 'latest',

    [string]$ConfigPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Pass arguments to native tools as they are (empty strings and quotes too).
$PSNativeCommandArgumentPassing = 'Standard'

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

function Get-BuildVmConfig {
    param([string]$Path)
    if (-not $Path) {
        $Path = Join-Path $PSScriptRoot 'buildvm.config.psd1'
        if (-not (Test-Path $Path)) {
            $Path = Join-Path $PSScriptRoot 'buildvm.config.example.psd1'
        }
    }
    $config = Import-PowerShellDataFile -Path $Path
    foreach ($key in 'VmName', 'Cpus', 'MemoryGB', 'DiskGB', 'SwitchName', 'ImageRepo', 'Label', 'Repos') {
        if (-not $config.ContainsKey($key)) { throw "Config $Path has no '$key'." }
    }
    if (-not $config.ContainsKey('VmRoot') -or -not $config.VmRoot) {
        $config.VmRoot = (Get-VMHost).VirtualMachinePath
    }
    $config.VmDir = Join-Path $config.VmRoot $config.VmName
    $config.CacheDir = Join-Path $env:LOCALAPPDATA 'build-vm\images'
    $config.SshKey = Join-Path $config.VmDir 'id_ed25519'
    $config.KnownHosts = Join-Path $config.VmDir 'known_hosts'
    $config.Path = $Path
    return $config
}

# --------------------------------------------------------------------------
# Helpers: native tools
# --------------------------------------------------------------------------

function Invoke-Native {
    # Run a native tool and stop on a non-zero exit code.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $output = & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($ArgumentList -join ' ') failed (exit code $LASTEXITCODE)."
    }
    return $output
}

function Confirm-Tool {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not installed. $Hint"
    }
}

function Confirm-Gh {
    Confirm-Tool gh 'Install it with: winget install GitHub.cli'
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { throw 'gh is not logged in. Run: gh auth login' }
}

function Confirm-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this command in an admin PowerShell (Hyper-V needs it).'
    }
}

function Get-TargetRepo {
    param($Config, [string[]]$Name, [switch]$AllowEmpty)
    if ($Name) { return $Name }
    if (-not $Config.Repos -and -not $AllowEmpty) {
        throw "No repositories. Set Repos in $($Config.Path) (copy buildvm.config.example.psd1 to buildvm.config.psd1), or use -Repo owner/repo."
    }
    return $Config.Repos
}

function Get-RunnerName {
    # The same name as runner-add in the VM: <hostname>-<owner>-<repo>.
    param($Config, [string]$Name)
    return "$($Config.VmName)-$($Name -replace '/', '-')"
}

# --------------------------------------------------------------------------
# Helpers: VM
# --------------------------------------------------------------------------

function Get-BuildVm {
    param($Config)
    return Get-VM -Name $Config.VmName -ErrorAction SilentlyContinue
}

function Get-BuildVmIp {
    param($Config, [int]$TimeoutSec = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $ip = (Get-VMNetworkAdapter -VMName $Config.VmName).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' } |
            Select-Object -First 1
        if ($ip) { return $ip }
        Start-Sleep -Seconds 5
    }
    throw "The VM has no IP address after $TimeoutSec s. Check its network switch '$($Config.SwitchName)'."
}

function Get-SshArgument {
    param($Config, [string]$Ip, [switch]$Interactive)
    $batchMode = if ($Interactive) { 'no' } else { 'yes' }
    return @(
        '-i', $Config.SshKey,
        '-o', "BatchMode=$batchMode",
        '-o', 'ConnectTimeout=10',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=$($Config.KnownHosts)",
        "runner@$Ip"
    )
}

function Invoke-VmCommand {
    # Run a command in the VM over SSH. InputText goes to stdin (for tokens).
    param($Config, [Parameter(Mandatory)][string]$CommandLine, [string]$InputText)
    $ip = Get-BuildVmIp -Config $Config -TimeoutSec 60
    $sshArgs = (Get-SshArgument -Config $Config -Ip $ip) + $CommandLine
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $output = $InputText | & ssh @sshArgs
    }
    else {
        $output = & ssh @sshArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "Command in the VM failed: $CommandLine" }
    return $output
}

function Wait-BuildVmReady {
    # Wait for the IP address, SSH and the end of cloud-init (first boot).
    param($Config, [int]$TimeoutSec = 900)
    Write-Host "Waiting for the VM '$($Config.VmName)'..."
    $ip = Get-BuildVmIp -Config $Config -TimeoutSec $TimeoutSec
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $sshArgs = Get-SshArgument -Config $Config -Ip $ip
    while ($true) {
        & ssh @sshArgs 'cloud-init status --wait >/dev/null; true' 2> $null
        if ($LASTEXITCODE -eq 0) { break }
        if ((Get-Date) -gt $deadline) { throw "SSH to $ip does not work after $TimeoutSec s." }
        Start-Sleep -Seconds 5
    }
    Write-Host "VM is ready: runner@$ip"
}

function Write-Utf8LfFile {
    # cloud-init wants UTF-8 without BOM and Unix line ends.
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Build-SeedDisk {
    # A small FAT32 disk with the label CIDATA: the cloud-init NoCloud data source.
    # Docs: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html
    param($Config, [string]$Path, [string]$PublicKey)

    $metaData = @"
instance-id: $($Config.VmName)-$([guid]::NewGuid())
local-hostname: $($Config.VmName)
"@
    $userData = @"
#cloud-config
hostname: $($Config.VmName)
users:
  - name: runner
    ssh_authorized_keys:
      - $PublicKey
"@
    $networkConfig = @'
version: 2
ethernets:
  all:
    match:
      name: "e*"
    dhcp4: true
'@

    New-VHD -Path $Path -SizeBytes 128MB -Dynamic | Out-Null
    $disk = Mount-VHD -Path $Path -Passthru | Get-Disk
    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel CIDATA -Force -Confirm:$false | Out-Null
        $letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber).DriveLetter
        Write-Utf8LfFile -Path "${letter}:\meta-data" -Text $metaData
        Write-Utf8LfFile -Path "${letter}:\user-data" -Text $userData
        Write-Utf8LfFile -Path "${letter}:\network-config" -Text $networkConfig
    }
    finally {
        Dismount-VHD -Path $Path
    }
}

# --------------------------------------------------------------------------
# Helpers: image
# --------------------------------------------------------------------------

function Get-ImageTag {
    param($Config, [string]$Tag)
    if ($Tag -ne 'latest') { return $Tag }
    return Invoke-Native gh @('release', 'view', '--repo', $Config.ImageRepo, '--json', 'tagName', '--jq', '.tagName')
}

function Get-BaseImage {
    # Download the release parts, check them, and join them into a VHDX.
    # The VHDX stays in the cache for the next VM.
    param($Config, [string]$Tag)
    $dir = Join-Path $Config.CacheDir $Tag
    $vhdx = Join-Path $dir 'build-vm.vhdx'
    if (Test-Path $vhdx) { return $vhdx }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    Write-Host "Downloading image $Tag from $($Config.ImageRepo)..."
    Invoke-Native gh @('release', 'download', $Tag, '--repo', $Config.ImageRepo, '--dir', $dir, '--clobber',
        '--pattern', 'build-vm.vhdx.gz.part-*', '--pattern', 'SHA256SUMS', '--pattern', 'build-vm.vhdx.sha256') | Out-Null

    $parts = foreach ($line in Get-Content (Join-Path $dir 'SHA256SUMS') | Where-Object { $_.Trim() }) {
        $hash, $name = $line -split '\s+\*?', 2
        $file = Join-Path $dir $name
        if ((Get-FileHash -Algorithm SHA256 -Path $file).Hash -ne $hash) { throw "Bad SHA-256: $name" }
        $file
    }

    Write-Host 'Joining and unpacking the image (a few minutes)...'
    $output = [IO.File]::Create("$vhdx.tmp")
    try {
        $gzipFile = Join-Path $dir 'build-vm.vhdx.gz'
        $joined = [IO.File]::Create($gzipFile)
        try {
            foreach ($part in ($parts | Sort-Object)) {
                $source = [IO.File]::OpenRead($part)
                try { $source.CopyTo($joined) } finally { $source.Dispose() }
            }
        }
        finally { $joined.Dispose() }

        $gzip = [IO.Compression.GZipStream]::new([IO.File]::OpenRead($gzipFile), [IO.Compression.CompressionMode]::Decompress)
        try { $gzip.CopyTo($output) } finally { $gzip.Dispose() }
        Remove-Item -LiteralPath (@($gzipFile) + $parts)
    }
    finally { $output.Dispose() }

    $expected = (Get-Content (Join-Path $dir 'build-vm.vhdx.sha256') -Raw).Split(' ')[0]
    if ((Get-FileHash -Algorithm SHA256 -Path "$vhdx.tmp").Hash -ne $expected) {
        Remove-Item "$vhdx.tmp"
        throw 'Bad SHA-256 of the unpacked image.'
    }
    Move-Item "$vhdx.tmp" $vhdx
    return $vhdx
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

function Invoke-Install {
    param($Config, [string]$Tag)
    Confirm-Admin
    Confirm-Gh
    Confirm-Tool ssh 'Add the Windows feature "OpenSSH Client".'
    if (Get-BuildVm $Config) { throw "The VM '$($Config.VmName)' exists. Use Update, or Remove first." }

    $Tag = Get-ImageTag -Config $Config -Tag $Tag
    $baseImage = Get-BaseImage -Config $Config -Tag $Tag

    New-Item -ItemType Directory -Force -Path $Config.VmDir | Out-Null
    $disk = Join-Path $Config.VmDir "$($Config.VmName).vhdx"
    $seed = Join-Path $Config.VmDir 'seed.vhdx'
    Remove-Item $seed, $Config.KnownHosts -ErrorAction SilentlyContinue

    Write-Host 'Copying the disk...'
    Copy-Item $baseImage $disk
    if ((Get-VHD -Path $disk).Size -lt $Config.DiskGB * 1GB) {
        # cloud-init grows the partition on first boot.
        Resize-VHD -Path $disk -SizeBytes ($Config.DiskGB * 1GB)
    }

    if (-not (Test-Path $Config.SshKey)) {
        Invoke-Native ssh-keygen @('-q', '-t', 'ed25519', '-N', '', '-C', "build-vm@$env:COMPUTERNAME", '-f', $Config.SshKey) | Out-Null
    }
    Build-SeedDisk -Config $Config -Path $seed -PublicKey (Get-Content "$($Config.SshKey).pub" -Raw).Trim()

    Write-Host "Creating the VM '$($Config.VmName)'..."
    $vm = New-VM -Name $Config.VmName -Generation 2 -Path $Config.VmRoot -VHDPath $disk `
        -MemoryStartupBytes ($Config.MemoryGB * 1GB) -SwitchName $Config.SwitchName
    Set-VMProcessor -VM $vm -Count $Config.Cpus
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority `
        -FirstBootDevice (Get-VMHardDiskDrive -VM $vm | Select-Object -First 1)
    Add-VMHardDiskDrive -VM $vm -Path $seed
    Set-VM -VM $vm -AutomaticStartAction Start -AutomaticStopAction ShutDown `
        -AutomaticCheckpointsEnabled $false -Notes "build-vm image $Tag"
    Start-VM -VM $vm
    Wait-BuildVmReady -Config $Config
    Write-Host "Next: .\BuildVm.ps1 Register"
}

function Invoke-Register {
    param($Config, [string[]]$Names)
    Confirm-Gh
    foreach ($name in Get-TargetRepo -Config $Config -Name $Names) {
        Write-Host "${name}: adding the runner..."
        $token = Invoke-Native gh @('api', '-X', 'POST', "repos/$name/actions/runners/registration-token", '--jq', '.token')
        Invoke-VmCommand -Config $Config -CommandLine "sudo runner-add $name $($Config.Label)" -InputText $token
        Invoke-Native gh @('variable', 'set', 'RUNNER', '--body', $Config.Label, '--repo', $name) | Out-Null
        Write-Host "${name}: RUNNER=$($Config.Label)"
    }
}

function Invoke-Unregister {
    param($Config, [string[]]$Names, [switch]$AllowEmpty)
    Confirm-Gh
    $vmRunning = (Get-BuildVm $Config) -and (Get-BuildVm $Config).State -eq 'Running'
    foreach ($name in Get-TargetRepo -Config $Config -Name $Names -AllowEmpty:$AllowEmpty) {
        Write-Host "${name}: removing the runner..."
        Disable-Repo -Name $name
        if ($vmRunning) {
            $token = Invoke-Native gh @('api', '-X', 'POST', "repos/$name/actions/runners/remove-token", '--jq', '.token')
            Invoke-VmCommand -Config $Config -CommandLine "sudo runner-remove $name" -InputText $token
        }
        # When the VM is off (or the remove failed), delete the runner on GitHub directly.
        $runnerName = Get-RunnerName -Config $Config -Name $name
        $ids = Invoke-Native gh @('api', "repos/$name/actions/runners", '--paginate',
            '--jq', ".runners[] | select(.name == `"$runnerName`") | .id")
        foreach ($id in $ids) {
            Invoke-Native gh @('api', '-X', 'DELETE', "repos/$name/actions/runners/$id") | Out-Null
        }
    }
}

function Enable-Repo {
    param($Config, [string]$Name)
    Invoke-Native gh @('variable', 'set', 'RUNNER', '--body', $Config.Label, '--repo', $Name) | Out-Null
    Write-Host "${Name}: RUNNER=$($Config.Label) (jobs go to the VM)"
}

function Disable-Repo {
    param([string]$Name)
    & gh variable delete RUNNER --repo $Name *> $null
    Write-Host "${Name}: RUNNER removed (jobs go to GitHub-hosted runners)"
}

function Invoke-Status {
    param($Config, [string[]]$Names)
    $vm = Get-BuildVm $Config
    if ($vm) {
        $ip = ($vm | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        Write-Host "VM '$($vm.Name)': $($vm.State), IP $ip, $($vm.Notes)"
    }
    else {
        Write-Host "VM '$($Config.VmName)': not installed"
    }

    Confirm-Gh
    $rows = foreach ($name in Get-TargetRepo -Config $Config -Name $Names) {
        $variable = & gh variable get RUNNER --repo $name 2> $null
        if ($LASTEXITCODE -ne 0) { $variable = '' }
        $runnerName = Get-RunnerName -Config $Config -Name $name
        $runner = Invoke-Native gh @('api', "repos/$name/actions/runners", '--paginate',
            '--jq', ".runners[] | select(.name == `"$runnerName`") | `"\(.status)\(if .busy then `" (busy)`" else `"`" end)`"")
        [pscustomobject]@{
            Repository = $name
            Variable   = if ($variable) { "RUNNER=$variable" } else { '(not set)' }
            Runner     = if ($runner) { $runner } else { '(none)' }
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Invoke-Remove {
    param($Config)
    Confirm-Admin
    $vm = Get-BuildVm $Config
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
        Remove-VM -VM $vm -Force
    }
    if (Test-Path $Config.VmDir) { Remove-Item -Recurse -Force $Config.VmDir }
    Write-Host "VM '$($Config.VmName)' removed."
}

function Confirm-Action {
    param([string]$Message, [switch]$Yes)
    if ($Yes) { return }
    $answer = Read-Host "$Message Type 'yes' to go on"
    if ($answer -ne 'yes') { throw 'Stopped.' }
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

$config = Get-BuildVmConfig -Path $ConfigPath

switch ($Command) {
    'Install' { Invoke-Install -Config $config -Tag $Version }
    'Register' { Invoke-Register -Config $config -Names $Repo }
    'Unregister' { Invoke-Unregister -Config $config -Names $Repo }
    'Enable' { Confirm-Gh; foreach ($name in Get-TargetRepo -Config $config -Name $Repo) { Enable-Repo -Config $config -Name $name } }
    'Disable' { Confirm-Gh; foreach ($name in Get-TargetRepo -Config $config -Name $Repo) { Disable-Repo -Name $name } }
    'Start' {
        Confirm-Admin
        $vm = Get-BuildVm $config
        if (-not $vm) { throw "The VM '$($config.VmName)' is not installed. Run Install." }
        if ($vm.State -ne 'Running') { Start-VM -VM $vm }
        Wait-BuildVmReady -Config $config
    }
    'Stop' {
        Confirm-Admin
        $vm = Get-BuildVm $config
        if ($vm -and $vm.State -eq 'Running') { Stop-VM -VM $vm }
        Write-Host "VM '$($config.VmName)' is off. Jobs wait in the queue until Start, or use Disable."
    }
    'Status' { Invoke-Status -Config $config -Names $Repo }
    'Ssh' {
        $ip = Get-BuildVmIp -Config $config -TimeoutSec 30
        $sshArgs = Get-SshArgument -Config $config -Ip $ip -Interactive
        & ssh @sshArgs
    }
    'Update' {
        Confirm-Action "This removes the VM '$($config.VmName)' and installs image '$Version'." -Yes:$Force
        Invoke-Unregister -Config $config -AllowEmpty
        Invoke-Remove -Config $config
        Invoke-Install -Config $config -Tag $Version
        Invoke-Register -Config $config
    }
    'Remove' {
        Confirm-Action "This removes the runners, the RUNNER variables and the VM '$($config.VmName)'." -Yes:$Force
        Invoke-Unregister -Config $config -AllowEmpty
        Invoke-Remove -Config $config
    }
}
