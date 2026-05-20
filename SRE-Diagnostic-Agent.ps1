#Requires -Version 5.1
<#
.SYNOPSIS
    SRE Diagnostic Agent - Comprehensive OS-Level Health Check

.DESCRIPTION
    Diagnoses CPU, Memory, Disk, Network, Services, Processes, Event Logs,
    and Performance Counters. Outputs a prioritized list of findings with
    severity levels (CRITICAL, WARNING, INFO).

.NOTES
    Run as Administrator for full access to all diagnostics.
    Usage: .\SRE-Diagnostic-Agent.ps1
           .\SRE-Diagnostic-Agent.ps1 -ExportReport -ReportPath "C:\Logs\sre-report.txt"
#>

[CmdletBinding()]
param(
    [switch]$ExportReport,
    [string]$ReportPath = ".\SRE-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
)

# ─────────────────────────────────────────────
#  CONFIGURATION — Tune thresholds here
# ─────────────────────────────────────────────
$Config = @{
    CPU = @{
        CriticalPercent = 90
        WarningPercent  = 75
        SampleSeconds   = 5       # How long to sample CPU
    }
    Memory = @{
        CriticalPercent = 90
        WarningPercent  = 75
    }
    Disk = @{
        CriticalFreePercent = 10
        WarningFreePercent  = 20
        CriticalFreeGB      = 5
    }
    Network = @{
        PingTargets         = @("8.8.8.8", "1.1.1.1", "google.com")
        HighLatencyMs       = 150
        FailLatencyMs       = 500
    }
    EventLog = @{
        LookbackHours       = 24
        CriticalEventIds    = @(41, 1001, 1002, 6008, 7034, 7031)  # Kernel power, app hang/crash, unexpected shutdown, service failures
        MaxEventsPerLog     = 20
    }
    Process = @{
        HighCpuPercent      = 80
        HighMemoryMB        = 1500
    }
    Services = @{
        # Services that MUST be running; add your critical services here
        Critical            = @(
            "wuauserv",   # Windows Update
            "WinDefend",  # Windows Defender
            "Dnscache",   # DNS Client
            "LanmanServer", # Server (file sharing)
            "Spooler"     # Print Spooler (common cause of issues)
        )
    }
}

# ─────────────────────────────────────────────
#  FINDINGS COLLECTOR
# ─────────────────────────────────────────────
$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param(
        [ValidateSet("CRITICAL","WARNING","INFO")]
        [string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$Detail
    )
    $Findings.Add([PSCustomObject]@{
        Severity = $Severity
        Category = $Category
        Title    = $Title
        Detail   = $Detail
    })
}

# ─────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────
function Write-Header {
    param([string]$Text)
    $line = "─" * 60
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$line" -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Text, [string]$Color = "Gray")
    Write-Host "  → $Text" -ForegroundColor $Color
}

function Get-PercentUsed {
    param([double]$Used, [double]$Total)
    if ($Total -eq 0) { return 0 }
    return [math]::Round(($Used / $Total) * 100, 1)
}

# ─────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────
Clear-Host
$banner = @"
╔══════════════════════════════════════════════════════════════╗
║           SRE DIAGNOSTIC AGENT  —  OS Health Check          ║
║                $(Get-Date -Format 'yyyy-MM-dd  HH:mm:ss')                        ║
║          Host: $($env:COMPUTERNAME.PadRight(20)) User: $($env:USERNAME)
╚══════════════════════════════════════════════════════════════╝
"@
Write-Host $banner -ForegroundColor Cyan

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "  [!] Not running as Administrator — some checks may be limited." -ForegroundColor Yellow
}

# ════════════════════════════════════════════
#  1. CPU
# ════════════════════════════════════════════
Write-Header "1 / 7  CPU"

try {
    Write-Status "Sampling CPU for $($Config.CPU.SampleSeconds) seconds..."
    $cpuLoad = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average

    $logicalCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $physicalCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum

    Write-Status "CPU Load: $cpuLoad%  |  Physical: $physicalCores cores  |  Logical: $logicalCores"

    if ($cpuLoad -ge $Config.CPU.CriticalPercent) {
        Add-Finding CRITICAL CPU "CPU at $cpuLoad% — critically high" `
            "System is severely CPU-bound ($cpuLoad% used). Check top processes below."
    } elseif ($cpuLoad -ge $Config.CPU.WarningPercent) {
        Add-Finding WARNING CPU "CPU at $cpuLoad% — elevated" `
            "CPU load is above warning threshold ($($Config.CPU.WarningPercent)%). Monitor for sustained pressure."
    } else {
        Add-Finding INFO CPU "CPU healthy at $cpuLoad%" "No action needed."
    }

    # Top CPU consumers
    $topProcs = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5
    $topList = ($topProcs | ForEach-Object { "$($_.Name) (PID $($_.Id)): $([math]::Round($_.CPU,1))s CPU time" }) -join "; "
    Add-Finding INFO CPU "Top CPU processes" $topList

} catch {
    Add-Finding WARNING CPU "CPU check failed" $_.Exception.Message
}

# ════════════════════════════════════════════
#  2. MEMORY
# ════════════════════════════════════════════
Write-Header "2 / 7  Memory"

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMB  = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
    $freeMB   = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    $usedMB   = $totalMB - $freeMB
    $usedPct  = Get-PercentUsed $usedMB $totalMB

    Write-Status "RAM: $usedMB MB used / $totalMB MB total ($usedPct%)"

    if ($usedPct -ge $Config.Memory.CriticalPercent) {
        Add-Finding CRITICAL Memory "Memory at $usedPct% — critically high" `
            "Only $freeMB MB free of $totalMB MB. Risk of paging/OOM. Identify and reduce memory consumers."
    } elseif ($usedPct -ge $Config.Memory.WarningPercent) {
        Add-Finding WARNING Memory "Memory at $usedPct% — elevated" `
            "$freeMB MB free. Above warning threshold. Monitor for growth."
    } else {
        Add-Finding INFO Memory "Memory healthy at $usedPct% ($freeMB MB free)" "No action needed."
    }

    # Page file usage
    $pf = Get-CimInstance Win32_PageFileUsage
    foreach ($p in $pf) {
        $pfPct = Get-PercentUsed $p.CurrentUsage $p.AllocatedBaseSize
        Write-Status "Page file $($p.Name): $($p.CurrentUsage) MB / $($p.AllocatedBaseSize) MB ($pfPct%)"
        if ($pfPct -gt 80) {
            Add-Finding WARNING Memory "Page file $($p.Name) at $pfPct%" `
                "Heavy paging detected. System is using virtual memory — RAM may be insufficient."
        }
    }

    # Top memory consumers
    $topMem = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5
    $memList = ($topMem | ForEach-Object { "$($_.Name) (PID $($_.Id)): $([math]::Round($_.WorkingSet64/1MB,0)) MB" }) -join "; "
    Add-Finding INFO Memory "Top memory processes" $memList

} catch {
    Add-Finding WARNING Memory "Memory check failed" $_.Exception.Message
}

# ════════════════════════════════════════════
#  3. DISK
# ════════════════════════════════════════════
Write-Header "3 / 7  Disk"

try {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null }

    foreach ($d in $drives) {
        $totalGB = [math]::Round(($d.Used + $d.Free) / 1GB, 1)
        $freeGB  = [math]::Round($d.Free / 1GB, 1)
        $usedGB  = [math]::Round($d.Used / 1GB, 1)
        $freePct = Get-PercentUsed $d.Free ($d.Used + $d.Free)

        Write-Status "Drive $($d.Name): $usedGB GB used / $totalGB GB total — $freeGB GB free ($freePct% free)"

        if ($freeGB -le $Config.Disk.CriticalFreeGB -or $freePct -le $Config.Disk.CriticalFreePercent) {
            Add-Finding CRITICAL Disk "Drive $($d.Name): critically low — $freeGB GB free ($freePct%)" `
                "Immediate action required. Disk is nearly full. Free space or expand volume."
        } elseif ($freePct -le $Config.Disk.WarningFreePercent) {
            Add-Finding WARNING Disk "Drive $($d.Name): low space — $freeGB GB free ($freePct%)" `
                "Below warning threshold. Plan cleanup or expansion."
        } else {
            Add-Finding INFO Disk "Drive $($d.Name) healthy — $freeGB GB free ($freePct%)" "No action needed."
        }
    }

    # Check for disk errors in event log
    $diskErrors = Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        Id        = @(7, 11, 15, 51, 52, 55)
        StartTime = (Get-Date).AddHours(-$Config.EventLog.LookbackHours)
    } -ErrorAction SilentlyContinue

    if ($diskErrors) {
        Add-Finding WARNING Disk "$($diskErrors.Count) disk I/O error(s) in last $($Config.EventLog.LookbackHours)h" `
            "Event IDs found: $(($diskErrors | Select-Object -ExpandProperty Id -Unique) -join ', '). Check disk health with chkdsk."
    }

} catch {
    Add-Finding WARNING Disk "Disk check failed" $_.Exception.Message
}

# ════════════════════════════════════════════
#  4. NETWORK
# ════════════════════════════════════════════
Write-Header "4 / 7  Network"

try {
    # Adapter status
    $adapters = Get-NetAdapter | Where-Object { $_.Status -ne "Not Present" }
    foreach ($a in $adapters) {
        Write-Status "Adapter '$($a.Name)': $($a.Status)  Speed: $([math]::Round($a.LinkSpeed/1MB,0)) Mbps"
        if ($a.Status -eq "Up") {
            $ip = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            if ($ip) { Write-Status "  IP: $ip" }
        } elseif ($a.Status -ne "Disconnected") {
            Add-Finding WARNING Network "Adapter '$($a.Name)' is $($a.Status)" `
                "Network adapter is in an unexpected state."
        }
    }

    # Connectivity tests
    foreach ($target in $Config.Network.PingTargets) {
        $ping = Test-Connection -ComputerName $target -Count 3 -ErrorAction SilentlyContinue
        if (-not $ping) {
            Add-Finding CRITICAL Network "Cannot reach $target" `
                "All 3 ping attempts failed. Possible DNS or routing issue."
        } else {
            $avgMs = ($ping | Measure-Object -Property ResponseTime -Average).Average
            Write-Status "Ping $target — avg $([math]::Round($avgMs,0)) ms"
            if ($avgMs -ge $Config.Network.FailLatencyMs) {
                Add-Finding CRITICAL Network "Very high latency to $target — $([math]::Round($avgMs,0)) ms" `
                    "Network is severely degraded. Check routing, firewall, and NIC."
            } elseif ($avgMs -ge $Config.Network.HighLatencyMs) {
                Add-Finding WARNING Network "Elevated latency to $target — $([math]::Round($avgMs,0)) ms" `
                    "Latency above $($Config.Network.HighLatencyMs) ms threshold."
            }
        }
    }

    # DNS resolution
    try {
        $dns = Resolve-DnsName "google.com" -ErrorAction Stop
        Write-Status "DNS resolution: OK ($($dns[0].IPAddress))"
    } catch {
        Add-Finding CRITICAL Network "DNS resolution failed" `
            "Could not resolve 'google.com'. DNS service may be down or misconfigured."
    }

    # TCP/IP stats — check for excessive TIME_WAIT or CLOSE_WAIT
    $netstat = netstat -ano 2>$null
    $timeWait  = ($netstat | Select-String "TIME_WAIT").Count
    $closeWait = ($netstat | Select-String "CLOSE_WAIT").Count
    Write-Status "TCP TIME_WAIT: $timeWait  |  CLOSE_WAIT: $closeWait"
    if ($closeWait -gt 50) {
        Add-Finding WARNING Network "$closeWait TCP connections in CLOSE_WAIT" `
            "High CLOSE_WAIT count indicates an application is not closing connections properly."
    }

} catch {
    Add-Finding WARNING Network "Network check failed" $_.Exception.Message
}

# ════════════════════════════════════════════
#  5. SERVICES
# ════════════════════════════════════════════
Write-Header "5 / 7  Services"

try {
    # Check critical services
    foreach ($svcName in $Config.Services.Critical) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Add-Finding INFO Services "Service '$svcName' not found" "Not installed on this system."
        } elseif ($svc.Status -ne "Running") {
            Add-Finding CRITICAL Services "Critical service '$($svc.DisplayName)' is $($svc.Status)" `
                "Service '$svcName' should be Running. Start-Service $svcName to remediate."
        } else {
            Write-Status "$($svc.DisplayName): $($svc.Status)"
        }
    }

    # Find any auto-start services that are stopped
    $stoppedAuto = Get-WmiObject Win32_Service |
        Where-Object { $_.StartMode -eq "Auto" -and $_.State -ne "Running" -and $_.State -ne "Paused" }

    if ($stoppedAuto) {
        foreach ($s in $stoppedAuto) {
            Add-Finding WARNING Services "Auto-start service '$($s.DisplayName)' is $($s.State)" `
                "Service '$($s.Name)' is set to Auto but is not running. Check for errors in Event Log."
        }
    } else {
        Write-Status "All auto-start services are running."
        Add-Finding INFO Services "All auto-start services running" "No stopped auto-start services detected."
    }

} catch {
    Add-Finding WARNING Services "Services check failed" $_.Exception.Message
}

# ════════════════════════════════════════════
#  6. EVENT LOG
# ════════════════════════════════════════════
Write-Header "6 / 7  Event Logs (last $($Config.EventLog.LookbackHours)h)"

$logsToCheck = @("System", "Application")

foreach ($logName in $logsToCheck) {
    try {
        # Critical errors
        $critEvents = Get-WinEvent -FilterHashtable @{
            LogName   = $logName
            Level     = 1,2   # Critical=1, Error=2
            StartTime = (Get-Date).AddHours(-$Config.EventLog.LookbackHours)
        } -MaxEvents $Config.EventLog.MaxEventsPerLog -ErrorAction SilentlyContinue

        if ($critEvents) {
            $grouped = $critEvents | Group-Object Id | Sort-Object Count -Descending
            foreach ($g in $grouped | Select-Object -First 5) {
                $sample = $g.Group[0]
                $sev = if ($sample.Level -eq 1) { "CRITICAL" } else { "WARNING" }
                Add-Finding $sev "EventLog[$logName]" `
                    "Event ID $($g.Name) appeared $($g.Count)x — $($sample.ProviderName)" `
                    $sample.Message.Substring(0, [math]::Min(300, $sample.Message.Length))
            }
            Write-Status "$logName: $($critEvents.Count) error/critical event(s) found"
        } else {
            Write-Status "$logName: No critical errors in last $($Config.EventLog.LookbackHours)h"
            Add-Finding INFO "EventLog[$logName]" "No critical errors in last $($Config.EventLog.LookbackHours)h" "Clean."
        }

        # Specific known-bad event IDs
        $knownBad = Get-WinEvent -FilterHashtable @{
            LogName   = "System"
            Id        = $Config.EventLog.CriticalEventIds
            StartTime = (Get-Date).AddHours(-$Config.EventLog.LookbackHours)
        } -ErrorAction SilentlyContinue

        if ($knownBad) {
            foreach ($ev in ($knownBad | Group-Object Id)) {
                $desc = switch ($ev.Name) {
                    41    { "Kernel power — unexpected reboot/crash" }
                    1001  { "Application crash (Windows Error Reporting)" }
                    1002  { "Application hang" }
                    6008  { "Unexpected shutdown" }
                    7034  { "Service crashed unexpectedly" }
                    7031  { "Service terminated unexpectedly" }
                    default { "Known issue event" }
                }
                Add-Finding CRITICAL "EventLog[System]" "Event $($ev.Name) ($($ev.Count)x): $desc" `
                    "Last occurrence: $($ev.Group[0].TimeCreated)"
            }
        }

    } catch {
        Write-Status "$logName log check skipped: $($_.Exception.Message)" Yellow
    }
}

# ════════════════════════════════════════════
#  7. PERFORMANCE COUNTERS & PROCESSES
# ════════════════════════════════════════════
Write-Header "7 / 7  Performance Counters & Processes"

try {
    # System uptime
    $os = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Status "System uptime: $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
    if ($uptime.TotalHours -lt 1) {
        Add-Finding WARNING System "System rebooted less than 1 hour ago" `
            "Last boot: $($os.LastBootUpTime). Recent reboot may indicate a crash or forced restart."
    } else {
        Add-Finding INFO System "Uptime: $($uptime.Days)d $($uptime.Hours)h" "System has been stable."
    }

    # Processor queue length (sustained >2 per core = bottleneck)
    try {
        $pql = (Get-Counter '\System\Processor Queue Length' -ErrorAction Stop).CounterSamples[0].CookedValue
        $cores = (Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum
        Write-Status "Processor Queue Length: $pql  (cores: $cores)"
        if ($pql -gt ($cores * 2)) {
            Add-Finding WARNING CPU "Processor queue length $pql exceeds threshold ($($cores * 2))" `
                "CPU is being queued. More threads are waiting than the CPU can service. System may feel sluggish."
        }
    } catch { }

    # Memory — available MBytes
    try {
        $avail = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue
        Write-Status "Available Memory (counter): $avail MB"
    } catch { }

    # Processes with high CPU time or memory
    $highMemProcs = Get-Process | Where-Object { $_.WorkingSet64 / 1MB -gt $Config.Process.HighMemoryMB } |
        Sort-Object WorkingSet64 -Descending

    foreach ($p in $highMemProcs) {
        $memMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
        Add-Finding WARNING Process "Process '$($p.Name)' (PID $($p.Id)) using $memMB MB RAM" `
            "Exceeds $($Config.Process.HighMemoryMB) MB threshold. Investigate if expected."
    }

    # Handle count — excessive handles can indicate leaks
    $handleHeavy = Get-Process | Sort-Object HandleCount -Descending | Select-Object -First 3
    $handleList = ($handleHeavy | ForEach-Object { "$($_.Name): $($_.HandleCount) handles" }) -join " | "
    Write-Status "Top handle consumers: $handleList"
    $highHandles = Get-Process | Where-Object { $_.HandleCount -gt 5000 }
    foreach ($p in $highHandles) {
        Add-Finding WARNING Process "Process '$($p.Name)' (PID $($p.Id)) has $($p.HandleCount) handles" `
            "Very high handle count. Possible handle leak."
    }

} catch {
    Add-Finding WARNING System "Perf counters check failed" $_.Exception.Message
}

# ════════════════════════════════════════════
#  FINAL REPORT
# ════════════════════════════════════════════
$line = "═" * 60

$reportLines = [System.Collections.Generic.List[string]]::new()

$reportLines.Add("")
$reportLines.Add($line)
$reportLines.Add("  SRE DIAGNOSTIC REPORT  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$reportLines.Add("  Host: $env:COMPUTERNAME   User: $env:USERNAME")
$reportLines.Add($line)

$criticals = $Findings | Where-Object Severity -eq "CRITICAL"
$warnings  = $Findings | Where-Object Severity -eq "WARNING"
$infos     = $Findings | Where-Object Severity -eq "INFO"

$summary = "  SUMMARY:  CRITICAL: $($criticals.Count)   WARNING: $($warnings.Count)   INFO: $($infos.Count)"
$reportLines.Add($summary)
$reportLines.Add($line)

foreach ($sev in @("CRITICAL","WARNING","INFO")) {
    $group = $Findings | Where-Object Severity -eq $sev
    if ($group.Count -eq 0) { continue }

    $reportLines.Add("")
    $reportLines.Add("  [$sev]")
    $reportLines.Add("  " + ("─" * 56))

    foreach ($f in $group) {
        $reportLines.Add("  [$($f.Category)]  $($f.Title)")
        $reportLines.Add("     └─ $($f.Detail)")
        $reportLines.Add("")
    }
}

$reportLines.Add($line)
$reportLines.Add("  END OF REPORT")
$reportLines.Add($line)

# Print to console with color
Write-Host ""
Write-Host $line -ForegroundColor Cyan
Write-Host "  SRE DIAGNOSTIC REPORT  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Host: $env:COMPUTERNAME   User: $env:USERNAME" -ForegroundColor Cyan
Write-Host $line -ForegroundColor Cyan

if ($criticals.Count -gt 0) {
    Write-Host "  CRITICAL: $($criticals.Count)" -ForegroundColor Red -NoNewline
} else {
    Write-Host "  CRITICAL: 0" -ForegroundColor Green -NoNewline
}
Write-Host "   WARNING: $($warnings.Count)" -ForegroundColor Yellow -NoNewline
Write-Host "   INFO: $($infos.Count)" -ForegroundColor Gray
Write-Host $line -ForegroundColor Cyan

foreach ($sev in @("CRITICAL","WARNING","INFO")) {
    $group = $Findings | Where-Object Severity -eq $sev
    if ($group.Count -eq 0) { continue }

    $color = switch ($sev) {
        "CRITICAL" { "Red" }
        "WARNING"  { "Yellow" }
        "INFO"     { "Gray" }
    }

    Write-Host ""
    Write-Host "  [$sev]" -ForegroundColor $color
    Write-Host "  $("─" * 56)" -ForegroundColor DarkGray

    foreach ($f in $group) {
        Write-Host "  [$($f.Category)]  $($f.Title)" -ForegroundColor $color
        Write-Host "     └─ $($f.Detail)" -ForegroundColor DarkGray
        Write-Host ""
    }
}

Write-Host $line -ForegroundColor Cyan
Write-Host "  END OF REPORT" -ForegroundColor Cyan
Write-Host $line -ForegroundColor Cyan

# Export if requested
if ($ExportReport) {
    $reportLines | Out-File -FilePath $ReportPath -Encoding UTF8
    Write-Host "`n  Report saved to: $ReportPath" -ForegroundColor Green
}
