<#
.SYNOPSIS
    Regenerates examples/sample-report.html from the fictional fixtures in tests/fixtures.
#>
[CmdletBinding()]
param()
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/ADHealthCheck.psm1') -Force
$fx = Join-Path $root 'tests/fixtures'

$checks = @()
foreach ($t in (Get-Content (Join-Path $fx 'dcdiag-sample.txt') | ConvertFrom-DcDiagOutput)) {
    $status = if ($t.Result -eq 'Passed') { 'OK' } else { 'Critical' }
    $checks += New-HealthCheckResult -Category 'dcdiag' -Name "$($t.Test) ($($t.Target))" -Status $status -Detail $t.Result
}
foreach ($r in (Get-Content -Raw (Join-Path $fx 'repadmin-replsummary-sample.txt') | ConvertFrom-RepadminReplSummary)) {
    $status = if ($r.Fails -gt 0) { 'Critical' } else { 'OK' }
    $checks += New-HealthCheckResult -Category 'Replication' -Name "$($r.Direction): $($r.DomainController)" -Status $status -Detail "Largest delta $($r.LargestDelta), $($r.Fails)/$($r.Total) failed $($r.ErrorText)".Trim()
}
foreach ($f in (Get-Content (Join-Path $fx 'netdom-fsmo-sample.txt') | ConvertFrom-NetdomFsmoOutput)) {
    $checks += New-HealthCheckResult -Category 'FSMO' -Name $f.Role -Status 'OK' -Detail $f.Holder
}
$checks += New-HealthCheckResult -Category 'Services' -Name 'NTDS' -Status 'OK' -Detail 'Running'
$checks += New-HealthCheckResult -Category 'Services' -Name 'DFSR' -Status 'OK' -Detail 'Running'
$checks += New-HealthCheckResult -Category 'Disk' -Name 'C:' -Status 'Warning' -Detail '14.2 GB free of 80 GB (17.8%)'
$checks += New-HealthCheckResult -Category 'System' -Name 'Pending reboot' -Status 'Warning' -Detail 'Windows Update'

$server = 'DC01 (fictional sample)'
ConvertTo-HealthCheckHtml -Check $checks -ComputerName $server -Title 'AD & Windows Server Health Check (SAMPLE OUTPUT)' -GeneratedAt ([datetime]'2026-10-24 09:00') |
    Set-Content -Path (Join-Path $PSScriptRoot 'sample-report.html') -Encoding UTF8
