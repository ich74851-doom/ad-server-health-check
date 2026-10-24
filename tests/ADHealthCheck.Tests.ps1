#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Platform-independent tests. Run with:  Invoke-Pester -Path ./tests -Output Detailed
#>

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/ADHealthCheck.psm1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Script and module hygiene' {
    It '<_> parses without errors' -ForEach @(
        Get-ChildItem -Path (Split-Path -Parent $PSScriptRoot) -Recurse -Include *.ps1, *.psm1 | Where-Object FullName -notmatch '[\\/]tests[\\/]' | ForEach-Object FullName
    ) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'every exported function has a synopsis' {
        foreach ($cmd in (Get-Command -Module ADHealthCheck)) {
            (Get-Help $cmd.Name).Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'ConvertFrom-DcDiagOutput' {
    BeforeAll {
        $script:tests = @(Get-Content (Join-Path $script:fixtures 'dcdiag-sample.txt') | ConvertFrom-DcDiagOutput)
    }
    It 'finds every test result line' { $script:tests.Count | Should -Be 9 }
    It 'detects the failed test' {
        $failed = @($script:tests | Where-Object Result -eq 'Failed')
        $failed.Count | Should -Be 1
        $failed[0].Test | Should -Be 'DFSREvent'
        $failed[0].Target | Should -Be 'DC01'
    }
    It 'parses enterprise tests against the domain name' {
        ($script:tests | Where-Object Test -eq 'LocatorCheck').Target | Should -Be 'corp.example.com'
    }
    It 'accepts a single multi-line string' {
        @(Get-Content -Raw (Join-Path $script:fixtures 'dcdiag-sample.txt') | ConvertFrom-DcDiagOutput).Count | Should -Be 9
    }
    It 'returns nothing for unrelated text' {
        @('hello', 'world' | ConvertFrom-DcDiagOutput).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-RepadminReplSummary' {
    BeforeAll {
        $script:rows = @(Get-Content -Raw (Join-Path $script:fixtures 'repadmin-replsummary-sample.txt') | ConvertFrom-RepadminReplSummary)
    }
    It 'parses source and destination rows' {
        @($script:rows | Where-Object Direction -eq 'Source').Count | Should -Be 3
        @($script:rows | Where-Object Direction -eq 'Destination').Count | Should -Be 2
    }
    It 'reads failure counts and error codes' {
        $dc2 = $script:rows | Where-Object { $_.Direction -eq 'Source' -and $_.DomainController -eq 'DC02' }
        $dc2.Fails | Should -Be 2
        $dc2.Total | Should -Be 10
        $dc2.FailPercent | Should -Be 20
        $dc2.ErrorCode | Should -Be 1722
    }
    It 'handles a healthy row with no error' {
        $dc1 = $script:rows | Where-Object { $_.Direction -eq 'Source' -and $_.DomainController -eq 'DC01' }
        $dc1.Fails | Should -Be 0
        $dc1.ErrorCode | Should -BeNullOrEmpty
    }
    It 'handles the >60 days delta' {
        ($script:rows | Where-Object DomainController -eq 'DC03').DeltaMinutes | Should -Be 86400
    }
}

Describe 'ConvertTo-DeltaMinute' {
    It 'converts <Delta> to <Expected> minutes' -ForEach @(
        @{ Delta = '12m:04s'; Expected = 12.07 }
        @{ Delta = '01h:02m:10s'; Expected = 62.17 }
        @{ Delta = '3d.04h:01m:00s'; Expected = 4561 }
        @{ Delta = ':00s'; Expected = 0 }
    ) {
        ConvertTo-DeltaMinute -Delta $Delta | Should -Be $Expected
    }
}

Describe 'ConvertFrom-NetdomFsmoOutput' {
    It 'returns all five roles with holders' {
        $roles = @(Get-Content (Join-Path $script:fixtures 'netdom-fsmo-sample.txt') | ConvertFrom-NetdomFsmoOutput)
        $roles.Count | Should -Be 5
        ($roles | Where-Object Role -eq 'PDC').Holder | Should -Be 'DC01.corp.example.com'
        ($roles | Where-Object Role -eq 'RID pool manager').Holder | Should -Be 'DC02.corp.example.com'
    }
}

Describe 'Get-PendingRebootState' {
    It 'reports no reboot when no signal is set' {
        (Get-PendingRebootState).RebootPending | Should -BeFalse
    }
    It 'lists every reason that is set' {
        $r = Get-PendingRebootState -WindowsUpdate $true -PendingFileRename $true
        $r.RebootPending | Should -BeTrue
        $r.Reasons | Should -Be @('Windows Update', 'Pending file rename operations')
    }
}

Describe 'Get-DiskStatus' {
    It 'classifies volumes as OK, Warning and Critical' {
        $vols = @(
            [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 50GB }
            [pscustomobject]@{ DeviceID = 'D:'; Size = 100GB; FreeSpace = 15GB }
            [pscustomobject]@{ DeviceID = 'E:'; Size = 100GB; FreeSpace = 5GB }
        )
        $r = @($vols | Get-DiskStatus)
        $r.Status | Should -Be @('OK', 'Warning', 'Critical')
        $r[0].FreePercent | Should -Be 50
    }
    It 'skips zero-size volumes' {
        @([pscustomobject]@{ DeviceID = 'X:'; Size = 0; FreeSpace = 0 } | Get-DiskStatus).Count | Should -Be 0
    }
}

Describe 'Get-HealthSummary and report' {
    BeforeAll {
        $script:checks = @(
            New-HealthCheckResult -Category 'dcdiag' -Name 'Connectivity' -Status 'OK'
            New-HealthCheckResult -Category 'Disk' -Name 'C:' -Status 'Warning' -Detail '15% free'
            New-HealthCheckResult -Category 'Replication' -Name 'DC02' -Status 'Critical' -Detail '<script>x</script>'
        )
    }
    It 'rolls up to the worst status' {
        $s = Get-HealthSummary -Check $script:checks
        $s.Overall | Should -Be 'Critical'
        $s.OK | Should -Be 1; $s.Warning | Should -Be 1; $s.Critical | Should -Be 1
    }
    It 'is OK when every check is OK' {
        (Get-HealthSummary -Check @($script:checks[0])).Overall | Should -Be 'OK'
    }
    It 'HTML-encodes details' {
        $server = 'DC01'
        $html = ConvertTo-HealthCheckHtml -Check $script:checks -ComputerName $server
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Not -Match '<script>x'
        $html | Should -Match '<h2>Replication</h2>'
    }
}

Describe 'Invoke-ADHealthCheck.ps1 (offline mode)' {
    BeforeAll {
        $script:out = Join-Path ([IO.Path]::GetTempPath()) ("adhc-" + [guid]::NewGuid())
        $script:scriptPath = Join-Path $script:root 'scripts/Invoke-ADHealthCheck.ps1'
        $params = @(
            '-NoProfile', '-File', $script:scriptPath,
            '-DcDiagPath', (Join-Path $script:fixtures 'dcdiag-sample.txt'),
            '-RepadminPath', (Join-Path $script:fixtures 'repadmin-replsummary-sample.txt'),
            '-FsmoPath', (Join-Path $script:fixtures 'netdom-fsmo-sample.txt'),
            '-SkipLocalChecks', '-Json', '-OutputPath', $script:out
        )
        $script:output = & (Get-Process -Id $PID).Path @params
        $script:exitCode = $LASTEXITCODE
    }
    AfterAll { Remove-Item -Recurse -Force $script:out -ErrorAction SilentlyContinue }

    It 'exits 2 because the fixtures contain critical findings' { $script:exitCode | Should -Be 2 }
    It 'writes an HTML and a JSON report' {
        @(Get-ChildItem $script:out -Filter *.html).Count | Should -Be 1
        @(Get-ChildItem $script:out -Filter *.json).Count | Should -Be 1
    }
    It 'reports the failed dcdiag test and replication failures' {
        $json = Get-Content (Get-ChildItem $script:out -Filter *.json).FullName -Raw | ConvertFrom-Json
        @($json | Where-Object { $_.Category -eq 'dcdiag' -and $_.Status -eq 'Critical' }).Count | Should -Be 1
        @($json | Where-Object { $_.Category -eq 'Replication' -and $_.Status -eq 'Critical' }).Count | Should -Be 3
        @($json | Where-Object Category -eq 'FSMO').Count | Should -Be 5
    }
}
