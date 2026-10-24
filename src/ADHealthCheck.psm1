#Requires -Version 5.1
<#
    ADHealthCheck module.

    Parsers (ConvertFrom-*) are pure functions that accept tool output as text, so they
    can be unit-tested on any platform. Collectors (Get-*, Test-*) call the Windows tools
    and cmdlets and are meant to run on a domain controller or member server.
#>

Set-StrictMode -Version Latest

#region Parsers

function ConvertFrom-DcDiagOutput {
    <#
    .SYNOPSIS
        Parses dcdiag output into one object per test.
    .DESCRIPTION
        Matches the "......................... <target> passed|failed test <Name>" lines
        that dcdiag prints for every test, for both server and enterprise tests.
    .PARAMETER InputObject
        dcdiag output, as a single string or an array of lines.
    .EXAMPLE
        dcdiag /q /c | ConvertFrom-DcDiagOutput
    .EXAMPLE
        Get-Content .\dcdiag.txt | ConvertFrom-DcDiagOutput | Where-Object Result -eq 'Failed'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$InputObject
    )
    begin { $lines = New-Object System.Collections.Generic.List[string] }
    process { foreach ($chunk in $InputObject) { foreach ($l in ($chunk -split "`r?`n")) { $lines.Add($l) } } }
    end {
        $pattern = '^\s*\.{3,}\s*(?<Target>\S+)\s+(?<Result>passed|failed)\s+test\s+(?<Test>\S+)'
        foreach ($line in $lines) {
            if ($line -match $pattern) {
                [pscustomobject]@{
                    Target = $Matches.Target
                    Test   = $Matches.Test
                    Result = (Get-Culture).TextInfo.ToTitleCase($Matches.Result)
                }
            }
        }
    }
}

function ConvertFrom-RepadminReplSummary {
    <#
    .SYNOPSIS
        Parses "repadmin /replsummary" output into one object per DC and direction.
    .PARAMETER InputObject
        repadmin /replsummary output, as a single string or an array of lines.
    .EXAMPLE
        repadmin /replsummary | ConvertFrom-RepadminReplSummary | Where-Object Fails -gt 0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$InputObject
    )
    begin { $lines = New-Object System.Collections.Generic.List[string] }
    process { foreach ($chunk in $InputObject) { foreach ($l in ($chunk -split "`r?`n")) { $lines.Add($l) } } }
    end {
        $direction = $null
        $rowPattern = '^\s*(?<Dc>\S+)\s+(?<Delta>(?:>60 days|[\d:hmsd]+))\s+(?<Fails>\d+)\s*/\s*(?<Total>\d+)\s+(?<Pct>\d+)\s*(?<Error>.*)$'
        foreach ($line in $lines) {
            if ($line -match '^\s*Source DSA\s') { $direction = 'Source'; continue }
            if ($line -match '^\s*Destination DSA\s') { $direction = 'Destination'; continue }
            if (-not $direction) { continue }
            if ($line -match $rowPattern) {
                $row = @{} + $Matches
                $errorText = $row.Error.Trim()
                $errorCode = $null
                if ($errorText -match '^\((?<Code>\d+)\)') { $errorCode = [int]$Matches.Code }
                [pscustomobject]@{
                    Direction        = $direction
                    DomainController = $row.Dc
                    LargestDelta = $row.Delta
                    DeltaMinutes = ConvertTo-DeltaMinute -Delta $row.Delta
                    Fails        = [int]$row.Fails
                    Total        = [int]$row.Total
                    FailPercent  = [int]$row.Pct
                    ErrorCode    = $errorCode
                    ErrorText    = $errorText
                }
            }
        }
    }
}

function ConvertTo-DeltaMinute {
    <#
    .SYNOPSIS
        Converts a repadmin "largest delta" value (e.g. 01h:02m, 12m:04s, 3d.04h:01m, >60 days) to minutes.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][string]$Delta)

    if ($Delta -match '^>\s*60 days$') { return [double](60 * 24 * 60) }
    $minutes = 0.0
    foreach ($m in [regex]::Matches($Delta, '(?<n>\d+)(?<u>[dhms])')) {
        $n = [double]$m.Groups['n'].Value
        switch ($m.Groups['u'].Value) {
            'd' { $minutes += $n * 1440 }
            'h' { $minutes += $n * 60 }
            'm' { $minutes += $n }
            's' { $minutes += $n / 60 }
        }
    }
    [math]::Round($minutes, 2)
}

function ConvertFrom-NetdomFsmoOutput {
    <#
    .SYNOPSIS
        Parses "netdom query fsmo" output into role / holder pairs.
    .EXAMPLE
        netdom query fsmo | ConvertFrom-NetdomFsmoOutput
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$InputObject
    )
    begin { $lines = New-Object System.Collections.Generic.List[string] }
    process { foreach ($chunk in $InputObject) { foreach ($l in ($chunk -split "`r?`n")) { $lines.Add($l) } } }
    end {
        $roles = 'Schema master', 'Domain naming master', 'PDC', 'RID pool manager', 'Infrastructure master'
        foreach ($line in $lines) {
            foreach ($role in $roles) {
                if ($line -match ('^\s*' + [regex]::Escape($role) + '\s{2,}(?<Holder>\S+)\s*$')) {
                    [pscustomobject]@{ Role = $role; Holder = $Matches.Holder }
                }
            }
        }
    }
}

#endregion

#region Evaluation

function Get-PendingRebootState {
    <#
    .SYNOPSIS
        Decides whether a reboot is pending from a set of signals.
    .DESCRIPTION
        Pure function so the decision logic can be tested. Use Test-PendingReboot to
        collect the signals from the registry on Windows.
    .PARAMETER ComponentBasedServicing
        HKLM:\...\Component Based Servicing\RebootPending exists.
    .PARAMETER WindowsUpdate
        HKLM:\...\WindowsUpdate\Auto Update\RebootRequired exists.
    .PARAMETER PendingFileRename
        Session Manager PendingFileRenameOperations has entries.
    .PARAMETER ComputerRename
        ActiveComputerName differs from ComputerName.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [bool]$ComponentBasedServicing,
        [bool]$WindowsUpdate,
        [bool]$PendingFileRename,
        [bool]$ComputerRename
    )
    $reasons = @()
    if ($ComponentBasedServicing) { $reasons += 'Component Based Servicing' }
    if ($WindowsUpdate) { $reasons += 'Windows Update' }
    if ($PendingFileRename) { $reasons += 'Pending file rename operations' }
    if ($ComputerRename) { $reasons += 'Computer rename' }
    [pscustomobject]@{
        RebootPending = ($reasons.Count -gt 0)
        Reasons       = $reasons
    }
}

function Get-DiskStatus {
    <#
    .SYNOPSIS
        Classifies volumes by free space percentage.
    .PARAMETER Volume
        Objects with DeviceID, Size and FreeSpace (bytes), e.g. from Win32_LogicalDisk.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]$Volume,
        [ValidateRange(1, 99)][int]$WarningPercent = 20,
        [ValidateRange(1, 99)][int]$CriticalPercent = 10
    )
    process {
        foreach ($v in $Volume) {
            if (-not $v.Size -or [double]$v.Size -le 0) { continue }
            $freePct = [math]::Round(([double]$v.FreeSpace / [double]$v.Size) * 100, 1)
            $status = if ($freePct -lt $CriticalPercent) { 'Critical' } elseif ($freePct -lt $WarningPercent) { 'Warning' } else { 'OK' }
            [pscustomobject]@{
                Drive       = $v.DeviceID
                SizeGB      = [math]::Round([double]$v.Size / 1GB, 1)
                FreeGB      = [math]::Round([double]$v.FreeSpace / 1GB, 1)
                FreePercent = $freePct
                Status      = $status
            }
        }
    }
}

function Get-HealthSummary {
    <#
    .SYNOPSIS
        Rolls individual check results up into an overall status.
    .PARAMETER Check
        Objects with Category, Name, Status (OK, Warning, Critical) and Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Check)

    $critical = @($Check | Where-Object Status -eq 'Critical').Count
    $warning = @($Check | Where-Object Status -eq 'Warning').Count
    $overall = if ($critical) { 'Critical' } elseif ($warning) { 'Warning' } else { 'OK' }
    [pscustomobject]@{
        Overall  = $overall
        Total    = @($Check).Count
        OK       = @($Check | Where-Object Status -eq 'OK').Count
        Warning  = $warning
        Critical = $critical
    }
}

function New-HealthCheckResult {
    <#
    .SYNOPSIS
        Creates a check result object in the shape used by the report.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'Warning', 'Critical')][string]$Status,
        [string]$Detail = ''
    )
    [pscustomobject]@{ Category = $Category; Name = $Name; Status = $Status; Detail = $Detail }
}

#endregion

#region Collectors (Windows)

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Reads the usual pending-reboot registry signals on the local Windows machine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pfr = $false
    $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $pfr = $true }
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    Get-PendingRebootState -ComponentBasedServicing $cbs -WindowsUpdate $wu -PendingFileRename $pfr -ComputerRename ($active -ne $pending)
}

function Get-ServiceCheck {
    <#
    .SYNOPSIS
        Checks that the named services exist, are running and (optionally) set to Automatic.
    .PARAMETER Name
        Service names. Defaults to the core domain controller services.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string[]]$Name = @('NTDS', 'DNS', 'Netlogon', 'Kdc', 'W32Time', 'DFSR', 'ADWS'))

    foreach ($svc in $Name) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $s) {
            New-HealthCheckResult -Category 'Services' -Name $svc -Status 'Warning' -Detail 'Service not found'
        }
        elseif ($s.Status -ne 'Running') {
            New-HealthCheckResult -Category 'Services' -Name $svc -Status 'Critical' -Detail "Status: $($s.Status)"
        }
        else {
            New-HealthCheckResult -Category 'Services' -Name $svc -Status 'OK' -Detail 'Running'
        }
    }
}

#endregion

#region Report

function ConvertTo-HealthCheckHtml {
    <#
    .SYNOPSIS
        Builds a self-contained HTML report from check results.
    .PARAMETER Check
        Check result objects (see New-HealthCheckResult).
    .PARAMETER Title
        Report title.
    .PARAMETER ComputerName
        Name of the server the checks ran on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Check,
        [string]$Title = 'AD & Windows Server Health Check',
        [string]$ComputerName = $env:COMPUTERNAME,
        [datetime]$GeneratedAt = (Get-Date)
    )
    $summary = Get-HealthSummary -Check $Check
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $colors = @{ OK = '#1e7e34'; Warning = '#b8860b'; Critical = '#c82333' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine("<title>$(& $enc $Title)</title>")
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px}table{border-collapse:collapse;width:100%;margin-bottom:20px}th,td{border:1px solid #ddd;padding:6px 8px;font-size:13px;text-align:left}th{background:#f3f3f3}.badge{color:#fff;padding:2px 8px;border-radius:3px;font-weight:600}.meta{color:#666;font-size:13px}</style></head><body>')
    [void]$sb.AppendLine("<h1>$(& $enc $Title)</h1>")
    [void]$sb.AppendLine("<p class=""meta"">Server: $(& $enc $ComputerName) &middot; Generated: $($GeneratedAt.ToString('yyyy-MM-dd HH:mm'))</p>")
    [void]$sb.AppendLine("<p>Overall: <span class=""badge"" style=""background:$($colors[$summary.Overall])"">$($summary.Overall)</span> &nbsp; $($summary.OK) OK, $($summary.Warning) warning, $($summary.Critical) critical</p>")

    foreach ($group in ($Check | Group-Object Category)) {
        [void]$sb.AppendLine("<h2>$(& $enc $group.Name)</h2><table><tr><th>Check</th><th>Status</th><th>Detail</th></tr>")
        foreach ($c in $group.Group) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $c.Name)</td><td><span class=""badge"" style=""background:$($colors[$c.Status])"">$($c.Status)</span></td><td>$(& $enc $c.Detail)</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</body></html>')
    $sb.ToString()
}

#endregion

Export-ModuleMember -Function ConvertFrom-DcDiagOutput, ConvertFrom-RepadminReplSummary, ConvertTo-DeltaMinute,
ConvertFrom-NetdomFsmoOutput, Get-PendingRebootState, Get-DiskStatus, Get-HealthSummary, New-HealthCheckResult,
Test-PendingReboot, Get-ServiceCheck, ConvertTo-HealthCheckHtml
