#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Active Directory and Windows Server health checks and writes an HTML report.

.DESCRIPTION
    Checks:
      - dcdiag test results (failed tests are Critical)
      - AD replication via repadmin /replsummary (failures and largest delta)
      - FSMO role holders (netdom query fsmo), and whether each holder resolves in DNS
      - Core DC services (NTDS, DNS, Netlogon, Kdc, W32Time, DFSR, ADWS)
      - Volume free space
      - Pending reboot

    Every tool-based check can read previously captured output instead (-DcDiagPath,
    -RepadminPath, -FsmoPath). This lets you review output collected elsewhere and
    produce a report offline, and it is how the test suite runs on Linux.

    Exit codes: 0 = all OK, 1 = warnings, 2 = critical findings. RMM and scheduled task
    monitors can alert on these.

.PARAMETER OutputPath
    Folder for the HTML report (and JSON if -Json is set). Default: .\reports

.PARAMETER DcDiagPath
    Read dcdiag output from this file instead of running dcdiag.

.PARAMETER RepadminPath
    Read repadmin /replsummary output from this file instead of running repadmin.

.PARAMETER FsmoPath
    Read netdom query fsmo output from this file instead of running netdom.

.PARAMETER SkipLocalChecks
    Skip the service, disk and pending-reboot checks (useful when reviewing captured
    output on another machine).

.PARAMETER MaxReplicationDeltaMinutes
    Largest replication delta allowed before a Warning. Default: 180.

.PARAMETER Json
    Also write the raw check results as JSON.

.PARAMETER PassThru
    Return the check result objects to the pipeline.

.EXAMPLE
    .\Invoke-ADHealthCheck.ps1
    Runs every check on the local domain controller and writes .\reports\ADHealth-<server>-<date>.html

.EXAMPLE
    .\Invoke-ADHealthCheck.ps1 -DcDiagPath .\dcdiag.txt -RepadminPath .\repl.txt -FsmoPath .\fsmo.txt -SkipLocalChecks
    Builds a report from output captured on a DC.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Get-Location) 'reports'),
    [string]$DcDiagPath,
    [string]$RepadminPath,
    [string]$FsmoPath,
    [switch]$SkipLocalChecks,
    [ValidateRange(1, 100000)][int]$MaxReplicationDeltaMinutes = 180,
    [ValidateRange(1, 99)][int]$DiskWarningPercent = 20,
    [ValidateRange(1, 99)][int]$DiskCriticalPercent = 10,
    [switch]$Json,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\ADHealthCheck.psm1') -Force

function Get-ToolOutput {
    param([string]$Path, [string]$Command, [string[]]$Arguments)
    if ($Path) { return (Get-Content -Path $Path -Raw) }
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { return $null }
    (& $Command @Arguments 2>&1 | Out-String)
}

$checks = New-Object System.Collections.Generic.List[object]
$computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }

# dcdiag
$dcdiag = Get-ToolOutput -Path $DcDiagPath -Command 'dcdiag.exe' -Arguments @('/c', '/v', '/skip:SystemLog')
if ($null -eq $dcdiag) {
    $checks.Add((New-HealthCheckResult -Category 'dcdiag' -Name 'dcdiag' -Status 'Warning' -Detail 'dcdiag not available (RSAT AD DS tools not installed?)'))
}
else {
    $tests = @($dcdiag | ConvertFrom-DcDiagOutput)
    if ($tests.Count -eq 0) {
        $checks.Add((New-HealthCheckResult -Category 'dcdiag' -Name 'dcdiag' -Status 'Warning' -Detail 'No test results found in dcdiag output'))
    }
    foreach ($t in $tests) {
        $status = if ($t.Result -eq 'Passed') { 'OK' } else { 'Critical' }
        $checks.Add((New-HealthCheckResult -Category 'dcdiag' -Name "$($t.Test) ($($t.Target))" -Status $status -Detail $t.Result))
    }
}

# Replication
$repl = Get-ToolOutput -Path $RepadminPath -Command 'repadmin.exe' -Arguments @('/replsummary')
if ($null -eq $repl) {
    $checks.Add((New-HealthCheckResult -Category 'Replication' -Name 'repadmin' -Status 'Warning' -Detail 'repadmin not available'))
}
else {
    foreach ($r in @($repl | ConvertFrom-RepadminReplSummary)) {
        $status = 'OK'
        $detail = "Largest delta $($r.LargestDelta), $($r.Fails)/$($r.Total) failed"
        if ($r.Fails -gt 0) { $status = 'Critical'; if ($r.ErrorText) { $detail += "; $($r.ErrorText)" } }
        elseif ($r.DeltaMinutes -gt $MaxReplicationDeltaMinutes) { $status = 'Warning'; $detail += " (exceeds $MaxReplicationDeltaMinutes min)" }
        $checks.Add((New-HealthCheckResult -Category 'Replication' -Name "$($r.Direction): $($r.DomainController)" -Status $status -Detail $detail))
    }
}

# FSMO
$fsmo = Get-ToolOutput -Path $FsmoPath -Command 'netdom.exe' -Arguments @('query', 'fsmo')
if ($null -eq $fsmo) {
    $checks.Add((New-HealthCheckResult -Category 'FSMO' -Name 'netdom' -Status 'Warning' -Detail 'netdom not available'))
}
else {
    $roles = @($fsmo | ConvertFrom-NetdomFsmoOutput)
    if ($roles.Count -ne 5) {
        $checks.Add((New-HealthCheckResult -Category 'FSMO' -Name 'Role count' -Status 'Warning' -Detail "Expected 5 FSMO roles, found $($roles.Count)"))
    }
    foreach ($role in $roles) {
        $status = 'OK'; $detail = $role.Holder
        if (-not $FsmoPath) {
            try { [void][System.Net.Dns]::GetHostEntry($role.Holder) }
            catch { $status = 'Critical'; $detail = "$($role.Holder) does not resolve in DNS" }
        }
        $checks.Add((New-HealthCheckResult -Category 'FSMO' -Name $role.Role -Status $status -Detail $detail))
    }
}

if (-not $SkipLocalChecks) {
    if ($IsLinux -or $IsMacOS) {
        Write-Warning 'Local service, disk and reboot checks need Windows; skipping them.'
    }
    else {
        foreach ($s in Get-ServiceCheck) { $checks.Add($s) }

        $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3'
        foreach ($d in @($volumes | Get-DiskStatus -WarningPercent $DiskWarningPercent -CriticalPercent $DiskCriticalPercent)) {
            $checks.Add((New-HealthCheckResult -Category 'Disk' -Name $d.Drive -Status $d.Status -Detail "$($d.FreeGB) GB free of $($d.SizeGB) GB ($($d.FreePercent)%)"))
        }

        $reboot = Test-PendingReboot
        $rebootStatus = if ($reboot.RebootPending) { 'Warning' } else { 'OK' }
        $rebootDetail = if ($reboot.RebootPending) { $reboot.Reasons -join ', ' } else { 'No reboot pending' }
        $checks.Add((New-HealthCheckResult -Category 'System' -Name 'Pending reboot' -Status $rebootStatus -Detail $rebootDetail))
    }
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$htmlPath = Join-Path $OutputPath "ADHealth-$computer-$stamp.html"
ConvertTo-HealthCheckHtml -Check $checks.ToArray() -ComputerName $computer | Set-Content -Path $htmlPath -Encoding UTF8
if ($Json) { $checks | ConvertTo-Json -Depth 4 | Set-Content -Path ([IO.Path]::ChangeExtension($htmlPath, '.json')) -Encoding UTF8 }

$summary = Get-HealthSummary -Check $checks.ToArray()
Write-Output "Overall: $($summary.Overall) ($($summary.OK) OK, $($summary.Warning) warning, $($summary.Critical) critical). Report: $htmlPath"
if ($PassThru) { $checks }

switch ($summary.Overall) { 'Critical' { exit 2 } 'Warning' { exit 1 } default { exit 0 } }
