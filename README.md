# AD & Windows Server Health Check

[![CI](https://github.com/ich74851-doom/ad-server-health-check/actions/workflows/ci.yml/badge.svg)](https://github.com/ich74851-doom/ad-server-health-check/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Windows%20Server-0078D6)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Overview

This project runs a single PowerShell health check for Active Directory domain controllers and
Windows Servers. It wraps `dcdiag`, `repadmin /replsummary` and `netdom query fsmo`, parses
their text output into objects, and adds service, disk and pending-reboot checks. The result is
one HTML report with an overall **OK / Warning / Critical** status and a matching exit code
that RMM tools and scheduled tasks can alert on.

I built it for the routine checks I run before and after backup and restore work, so that a
backup of a DC is only trusted when the DC itself is healthy.

## Features

- **dcdiag**: every test result is parsed, and any failed test is Critical
- **Replication**: per-DC source and destination failures, error codes and largest delta from
  `repadmin /replsummary`, with a configurable delta threshold
- **FSMO**: all five role holders, plus a check that each holder resolves in DNS
- **Services**: NTDS, DNS, Netlogon, KDC, W32Time, DFSR and ADWS are present and running
- **Disk**: free-space warning and critical thresholds per volume
- **Pending reboot**: CBS, Windows Update, pending file renames and computer rename
- **Offline mode**: build a report from output captured on another server
- **Output**: self-contained HTML, optional JSON, and exit codes `0` OK / `1` Warning / `2` Critical
- Works on Windows PowerShell 5.1 and PowerShell 7+, with no external modules

## Quick start

```powershell
git clone https://github.com/ich74851-doom/ad-server-health-check.git
cd ad-server-health-check
# On a domain controller (elevated PowerShell)
.\scripts\Invoke-ADHealthCheck.ps1
```

The report is written to `.\reports\ADHealth-<server>-<timestamp>.html`. You can see what it
looks like in [`examples/sample-report.html`](examples/sample-report.html). The sample is
generated from **fictional** fixture data.

## Usage

```powershell
# Full check with JSON output and a tighter replication threshold
.\scripts\Invoke-ADHealthCheck.ps1 -Json -MaxReplicationDeltaMinutes 60

# Build a report from output captured on a DC
dcdiag /c /v > dcdiag.txt; repadmin /replsummary > repl.txt; netdom query fsmo > fsmo.txt
.\scripts\Invoke-ADHealthCheck.ps1 -DcDiagPath .\dcdiag.txt -RepadminPath .\repl.txt -FsmoPath .\fsmo.txt -SkipLocalChecks

# Use the parsers directly
Import-Module .\src\ADHealthCheck.psm1
repadmin /replsummary | ConvertFrom-RepadminReplSummary | Where-Object Fails -gt 0
dcdiag /q | ConvertFrom-DcDiagOutput
```

| Parameter | Default | Purpose |
|---|---|---|
| `-OutputPath` | `.\reports` | Report folder |
| `-DcDiagPath` / `-RepadminPath` / `-FsmoPath` | (run tool) | Read captured output instead of running the tool |
| `-SkipLocalChecks` | off | Skip the service, disk and reboot checks |
| `-MaxReplicationDeltaMinutes` | `180` | Warning threshold for the largest replication delta |
| `-DiskWarningPercent` / `-DiskCriticalPercent` | `20` / `10` | Free-space thresholds |
| `-Json` | off | Also write the results as JSON |
| `-PassThru` | off | Return the result objects |

**Scheduling or RMM:** run the script as a scheduled task or RMM script, and alert on exit
code `1` or `2`. Requirements: RSAT AD DS tools (present on DCs) and local admin rights for
the service and registry checks.

## Project structure

```text
ad-server-health-check/
├── scripts/Invoke-ADHealthCheck.ps1   # entry point: runs checks, writes the report, sets the exit code
├── src/ADHealthCheck.psm1             # parsers, evaluation and HTML report functions
├── tests/                             # Pester tests and fictional tool-output fixtures
├── examples/                          # sample report (fictional) and the script that generates it
└── .github/workflows/ci.yml           # PSScriptAnalyzer + Pester
```

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The tests run on Linux, macOS and Windows. They use captured tool output with fictional
names (`corp.example.com`, `DC01`–`DC03`), so no domain is needed.

## Roadmap

- [ ] Time sync check (`w32tm /query /status`) with offset thresholds
- [ ] SYSVOL/DFSR backlog check (`dfsrdiag backlog`)
- [ ] AD backup age (`repadmin /showbackup`) to flag DCs without a recent system state backup
- [ ] Multi-DC mode that runs remotely against every DC in the domain

## License

[MIT](LICENSE) © Ishant Choudhary
