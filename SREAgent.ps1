#Requires -Version 5.1
Set-StrictMode -Off
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32GDI {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetGuiResources(IntPtr hProcess, uint uiFlags);
}
'@

# ─── Palette ──────────────────────────────────────────────────────────────────
$C = @{
    BgDark   = [System.Drawing.Color]::FromArgb(15,  15,  26)
    BgMid    = [System.Drawing.Color]::FromArgb(22,  22,  38)
    BgCard   = [System.Drawing.Color]::FromArgb(30,  30,  52)
    BgBar    = [System.Drawing.Color]::FromArgb(25,  25,  42)
    Accent   = [System.Drawing.Color]::FromArgb(0,  200, 255)
    White    = [System.Drawing.Color]::White
    Muted    = [System.Drawing.Color]::FromArgb(130, 130, 160)
    Ok       = [System.Drawing.Color]::FromArgb(80,  220, 120)
    Warn     = [System.Drawing.Color]::FromArgb(255, 190,  50)
    Err      = [System.Drawing.Color]::FromArgb(255,  80,  80)
    Blue     = [System.Drawing.Color]::FromArgb(0,   120, 180)
    DkGreen  = [System.Drawing.Color]::FromArgb(35,  100,  35)
    DkRed    = [System.Drawing.Color]::FromArgb(140,  30,  30)
    DkPurple = [System.Drawing.Color]::FromArgb(70,   50, 120)
    DkOrange = [System.Drawing.Color]::FromArgb(130,  70,   0)
    GridLine = [System.Drawing.Color]::FromArgb(45,  45,  68)
}
function PctColor($p) { if($p -gt 85){$C.Err}elseif($p -gt 65){$C.Warn}else{$C.Ok} }

# ─── Port Presets ─────────────────────────────────────────────────────────────
$PortPresets = [ordered]@{
    'DNS / AD'      = @(
        @{N='DNS TCP';          P=53;   Proto='TCP'}
        @{N='DNS UDP';          P=53;   Proto='UDP'}
        @{N='Kerberos';         P=88;   Proto='TCP'}
        @{N='LDAP';             P=389;  Proto='TCP'}
        @{N='LDAPS';            P=636;  Proto='TCP'}
        @{N='Global Catalog';   P=3268; Proto='TCP'}
        @{N='GC SSL';           P=3269; Proto='TCP'}
        @{N='RPC Endpoint';     P=135;  Proto='TCP'}
    )
    'SMB / File'    = @(
        @{N='SMB';              P=445;  Proto='TCP'}
        @{N='NetBIOS Session';  P=139;  Proto='TCP'}
        @{N='NetBIOS NS';       P=137;  Proto='UDP'}
        @{N='RPC';              P=135;  Proto='TCP'}
    )
    'Remote'        = @(
        @{N='RDP';              P=3389; Proto='TCP'}
        @{N='WinRM HTTP';       P=5985; Proto='TCP'}
        @{N='WinRM HTTPS';      P=5986; Proto='TCP'}
        @{N='SSH';              P=22;   Proto='TCP'}
    )
    'Web'           = @(
        @{N='HTTP';             P=80;   Proto='TCP'}
        @{N='HTTPS';            P=443;  Proto='TCP'}
        @{N='HTTP Alt';         P=8080; Proto='TCP'}
        @{N='HTTPS Alt';        P=8443; Proto='TCP'}
    )
    'Zerto'         = @(
        @{N='Zerto HTTPS';      P=443;  Proto='TCP'}
        @{N='ZVM to ZVM';       P=4007; Proto='TCP'}
        @{N='ZVM to VRA';       P=4008; Proto='TCP'}
        @{N='VRA to VRA';       P=4009; Proto='TCP'}
        @{N='Analytics';        P=9081; Proto='TCP'}
        @{N='Analytics 2';      P=9082; Proto='TCP'}
        @{N='Cloud Connector';  P=9669; Proto='TCP'}
    )
    'Silk'          = @(
        @{N='Silk HTTPS';       P=443;  Proto='TCP'}
        @{N='Silk HTTP';        P=80;   Proto='TCP'}
        @{N='Silk iSCSI';       P=3260; Proto='TCP'}
        @{N='Silk NFS';         P=2049; Proto='TCP'}
    )
    'Database'      = @(
        @{N='SQL Server';       P=1433; Proto='TCP'}
        @{N='SQL Browser';      P=1434; Proto='UDP'}
        @{N='MySQL';            P=3306; Proto='TCP'}
        @{N='PostgreSQL';       P=5432; Proto='TCP'}
        @{N='MongoDB';          P=27017;Proto='TCP'}
        @{N='Redis';            P=6379; Proto='TCP'}
    )
}

# ─── Data helpers ─────────────────────────────────────────────────────────────
function Get-CPUUsage { (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average }

function Get-MemInfo {
    $o = Get-CimInstance Win32_OperatingSystem
    $t = [math]::Round($o.TotalVisibleMemorySize/1MB,2)
    $f = [math]::Round($o.FreePhysicalMemory/1MB,2)
    $u = [math]::Round($t-$f,2)
    @{T=$t; U=$u; F=$f; Pct=[math]::Round($u/$t*100,1)}
}

function Get-DiskInfo {
    Get-CimInstance Win32_LogicalDisk | Where-Object DriveType -eq 3 |
        Select-Object DeviceID,
            @{N='Size(GB)'; E={[math]::Round($_.Size/1GB,1)}},
            @{N='Free(GB)'; E={[math]::Round($_.FreeSpace/1GB,1)}},
            @{N='Used%';    E={[math]::Round(($_.Size-$_.FreeSpace)/$_.Size*100,1)}}
}

function Get-GPUs  { Get-CimInstance Win32_VideoController | Select-Object Name,AdapterRAM,VideoModeDescription }
function Get-Nets  { Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object IPEnabled | Select-Object Description,IPAddress,DefaultIPGateway,MACAddress,DHCPEnabled }

function Get-TopProcs {
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 25 |
        Select-Object Name, Id,
            @{N='CPU(s)';  E={[math]::Round($_.CPU,1)}},
            @{N='RAM(MB)'; E={[math]::Round($_.WorkingSet64/1MB,1)}},
            @{N='Threads'; E={$_.Threads.Count}},
            @{N='Path';    E={try{$_.MainModule.FileName}catch{'—'}}}
}

function Get-WinEvents($log,$level,$hrs,$max=500,$srch='') {
    $flt = @{LogName=$log; StartTime=(Get-Date).AddHours(-$hrs)}
    $map = @{Critical=1;Error=2;Warning=3;Information=4}
    if ($level -ne 'All' -and $map[$level]) { $flt['Level']=$map[$level] }
    try {
        $ev = Get-WinEvent -FilterHashtable $flt -MaxEvents $max -EA Stop |
              Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message
        if ($srch) { $ev = $ev | Where-Object {$_.Message -like "*$srch*" -or $_.ProviderName -like "*$srch*"} }
        $ev
    } catch { @() }
}

function Test-TCP($h,[int]$p,[int]$ms=3000) {
    try {
        $tc  = New-Object System.Net.Sockets.TcpClient
        $iar = $tc.BeginConnect($h,$p,$null,$null)
        $ok  = $iar.AsyncWaitHandle.WaitOne($ms,$false)
        if ($ok -and $tc.Connected) { $tc.Close(); 'Open' } else { $tc.Close(); 'Closed' }
    } catch { 'Error' }
}

function Test-UDP($h,[int]$p,[int]$ms=2000) {
    try {
        $u = New-Object System.Net.Sockets.UdpClient
        $u.Client.ReceiveTimeout = $ms
        $u.Connect($h,$p)
        $u.Send([byte[]](0x00,0x01),2) | Out-Null
        try {
            $u.Receive([ref](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0))) | Out-Null
            $u.Close(); 'Open'
        } catch [System.Net.Sockets.SocketException] {
            $u.Close()
            if ($_.Exception.SocketErrorCode -eq 'ConnectionReset') {'Closed'} else {'Open (no reply)'}
        }
    } catch { 'Error' }
}

function Test-DNS($name,$svr,$type='A') {
    try {
        $a = @{Name=$name; Type=$type; ErrorAction='Stop'}
        if ($svr) { $a['Server']=$svr }
        @{OK=$true; R=Resolve-DnsName @a}
    } catch { @{OK=$false; Err=$_.Exception.Message} }
}

function Get-NTFS($path) {
    try { (Get-Acl $path -EA Stop).Access | Select-Object IdentityReference,
            @{N='Type';E={$_.AccessControlType}},
            @{N='Rights';E={$_.FileSystemRights}},
            @{N='Inherited';E={$_.IsInherited}},
            @{N='InheritFlags';E={$_.InheritanceFlags}},
            @{N='PropFlags';E={$_.PropagationFlags}}
    } catch { @() }
}

function Get-Shares { try { Get-SmbShare -EA Stop } catch { Get-CimInstance Win32_Share -EA SilentlyContinue } }
function Get-SharePerms($n) { try { Get-SmbShareAccess -Name $n -EA Stop } catch { @() } }

function Get-MyGroups {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $id.Groups | ForEach-Object {
        try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { $_.Value }
    } | Sort-Object
}

function Get-FWStatus   { try { Get-NetFirewallProfile -EA Stop | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction } catch { @() } }
function Get-DefStatus  { try { Get-MpComputerStatus -EA Stop } catch { $null } }
function Get-LocalUsrs  { try { Get-LocalUser  -EA Stop } catch { @() } }
function Get-LocalGrps  { try { Get-LocalGroup -EA Stop } catch { @() } }

function Test-Access($path) {
    $sb = [System.Text.StringBuilder]::new()
    $exists = Test-Path $path
    $sb.AppendLine("Path   : $path") | Out-Null
    $sb.AppendLine("User   : $env:USERDOMAIN\$env:USERNAME") | Out-Null
    $sb.AppendLine("Time   : $(Get-Date)") | Out-Null
    $sb.AppendLine('─'*65) | Out-Null
    $sb.AppendLine("Exists : $exists") | Out-Null
    if ($exists) {
        # Owner
        try { $acl=$null; $acl=Get-Acl $path -EA Stop; $sb.AppendLine("Owner  : $($acl.Owner)") | Out-Null } catch { $sb.AppendLine("Owner  : (cannot read)") | Out-Null }
        # Read
        try { Get-Item $path -EA Stop | Out-Null; $sb.AppendLine("Read   : ALLOWED") | Out-Null } catch { $sb.AppendLine("Read   : DENIED") | Out-Null }
        # List
        if (Test-Path $path -PathType Container) {
            try { Get-ChildItem $path -EA Stop | Out-Null; $sb.AppendLine("List   : ALLOWED") | Out-Null } catch { $sb.AppendLine("List   : DENIED") | Out-Null }
        }
        # Write
        $tmp = Join-Path (Split-Path $path -Parent) "__sre_$([System.IO.Path]::GetRandomFileName()).tmp"
        if (Test-Path $path -PathType Container) { $tmp = Join-Path $path "__sre_$([System.IO.Path]::GetRandomFileName()).tmp" }
        try {
            [System.IO.File]::WriteAllText($tmp,'SREAgent')
            Remove-Item $tmp -EA SilentlyContinue
            $sb.AppendLine("Write  : ALLOWED") | Out-Null
        } catch { $sb.AppendLine("Write  : DENIED") | Out-Null }
        # Delete
        try {
            $td = Join-Path (if(Test-Path $path -PathType Container){$path}else{Split-Path $path -Parent}) "__sre_del_$([System.IO.Path]::GetRandomFileName()).tmp"
            [System.IO.File]::WriteAllText($td,'x')
            Remove-Item $td -EA Stop
            $sb.AppendLine("Delete : ALLOWED") | Out-Null
        } catch { $sb.AppendLine("Delete : DENIED") | Out-Null }
    }
    $sb.ToString()
}

# ─── New data helpers ─────────────────────────────────────────────────────────

function Get-SysInfo {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $bio = Get-CimInstance Win32_BIOS
    $pf  = Get-CimInstance Win32_PageFileUsage
    $uptime = (Get-Date) - $os.LastBootUpTime
    $vm  = switch -Regex ($cs.Manufacturer) {
        'VMware'    {'VMware'}
        'Microsoft' { if($cs.Model -match 'Virtual'){'Hyper-V'}else{'Physical'} }
        'VirtualBox'{'VirtualBox'}
        'Xen'       {'Xen'}
        'QEMU'      {'QEMU/KVM'}
        default     {'Physical'}
    }
    # .NET versions from registry
    $nets = @()
    try {
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP' -Recurse -EA SilentlyContinue |
            Get-ItemProperty -Name Version,Release -EA SilentlyContinue |
            Where-Object Version | ForEach-Object {
                $n="$($_.PSChildName) $($_.Version)"; if($nets -notcontains $n){$nets+=$n}
            }
    } catch {}
    @{
        OSCaption   = $os.Caption
        OSBuild     = $os.BuildNumber
        OSArch      = $os.OSArchitecture
        InstallDate = $os.InstallDate
        LastBoot    = $os.LastBootUpTime
        Uptime      = "$([int]$uptime.TotalDays)d $($uptime.Hours)h $($uptime.Minutes)m"
        Computer    = $cs.Name
        Domain      = if($cs.PartOfDomain){$cs.Domain}else{"WORKGROUP: $($cs.Workgroup)"}
        Mfr         = $cs.Manufacturer
        Model       = $cs.Model
        RAM         = "$([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB"
        BIOSVer     = "$($bio.Manufacturer) $($bio.SMBIOSBIOSVersion)"
        BIOSDate    = $bio.ReleaseDate
        PageFile    = if($pf){"$($pf.Name)  $($pf.CurrentUsage) / $($pf.AllocatedBaseSize) MB"}else{'N/A'}
        DotNet      = ($nets | Select-Object -Unique | Sort-Object) -join ', '
        PSVer       = "$($PSVersionTable.PSVersion)"
        VM          = $vm
    }
}

function Get-UpdateHistory($max=50) {
    try {
        $sess    = New-Object -ComObject Microsoft.Update.Session
        $search  = $sess.CreateUpdateSearcher()
        $total   = $search.GetTotalHistoryCount()
        $count   = [math]::Min($max,$total)
        if($count -le 0){return @()}
        $search.QueryHistory(0,$count) | ForEach-Object {
            [PSCustomObject]@{
                Date        = $_.Date
                Title       = $_.Title
                Operation   = switch($_.Operation){1{'Install'} 2{'Uninstall'} default{'Other'}}
                ResultCode  = switch($_.ResultCode){1{'In Progress'} 2{'OK'} 3{'Error'} 4{'Aborted'} default{"$($_.ResultCode)"}}
                KB          = if($_.Title -match '(KB\d+)'){"$($Matches[1])"}else{''}
            }
        }
    } catch { @() }
}

function Get-PendingUpdates {
    try {
        $sess   = New-Object -ComObject Microsoft.Update.Session
        $srch   = $sess.CreateUpdateSearcher()
        $result = $srch.Search("IsInstalled=0 and IsHidden=0")
        $result.Updates | ForEach-Object {
            [PSCustomObject]@{
                Title      = $_.Title
                KB         = if($_.Title -match '(KB\d+)'){"$($Matches[1])"}else{''}
                Severity   = if($_.MsrcSeverity){$_.MsrcSeverity}else{'Unknown'}
                Size       = "$([math]::Round($_.MaxDownloadSize/1MB,1)) MB"
                Published  = $_.LastDeploymentChangeTime
            }
        }
    } catch { @() }
}

function Get-CertStore {
    $result = @()
    $stores = @('My','Root','CA','AuthRoot','TrustedPublisher')
    foreach ($sn in $stores) {
        try {
            $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($sn,'LocalMachine')
            $s.Open('ReadOnly')
            foreach ($c in $s.Certificates) {
                $days = ($c.NotAfter - (Get-Date)).Days
                $result += [PSCustomObject]@{
                    Store      = $sn
                    Subject    = ($c.Subject -replace 'CN=','') -split ',' | Select-Object -First 1
                    Issuer     = ($c.Issuer  -replace 'CN=','') -split ',' | Select-Object -First 1
                    Expires    = $c.NotAfter
                    DaysLeft   = $days
                    Thumbprint = $c.Thumbprint.Substring(0,16)+'…'
                    Status     = if($days -lt 0){'EXPIRED'}elseif($days -le 30){'EXPIRING'}else{'OK'}
                }
            }
            $s.Close()
        } catch {}
    }
    $result
}

function Get-TasksInfo {
    try {
        Get-ScheduledTask -EA Stop | ForEach-Object {
            $info = $_ | Get-ScheduledTaskInfo -EA SilentlyContinue
            $result = if($info.LastTaskResult -ne $null){$info.LastTaskResult}else{0}
            [PSCustomObject]@{
                Name       = $_.TaskName
                Path       = $_.TaskPath
                State      = $_.State
                LastRun    = if($info.LastRunTime  -and $info.LastRunTime  -gt [datetime]'1900-01-01'){$info.LastRunTime}else{'Never'}
                NextRun    = if($info.NextRunTime  -and $info.NextRunTime  -gt [datetime]'1900-01-01'){$info.NextRunTime}else{'—'}
                LastResult = "0x$('{0:X}' -f $result)"
                OK         = ($result -eq 0 -or $result -eq 267009)
            }
        }
    } catch { @() }
}

function Get-AutorunInfo {
    $items = @()
    $regPaths = @(
        @{Hive='HKLM';Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';         Scope='HKLM Run'}
        @{Hive='HKLM';Path='SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';     Scope='HKLM RunOnce'}
        @{Hive='HKCU';Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';         Scope='HKCU Run'}
        @{Hive='HKCU';Path='SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';     Scope='HKCU RunOnce'}
        @{Hive='HKLM';Path='SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope='HKLM Run (x86)'}
    )
    foreach ($rp in $regPaths) {
        try {
            $key = [Microsoft.Win32.Registry]::($rp.Hive).OpenSubKey($rp.Path)
            if ($key) {
                foreach ($v in $key.GetValueNames()) {
                    $items += [PSCustomObject]@{Source=$rp.Scope; Name=$v; Command=$key.GetValue($v)}
                }
                $key.Close()
            }
        } catch {}
    }
    # Startup folders
    $folders = @(
        @{Path=[System.Environment]::GetFolderPath('CommonStartup'); Scope='All Users Startup'}
        @{Path=[System.Environment]::GetFolderPath('Startup');       Scope='User Startup'}
    )
    foreach ($f in $folders) {
        try {
            Get-ChildItem $f.Path -EA Stop | ForEach-Object {
                $items += [PSCustomObject]@{Source=$f.Scope; Name=$_.Name; Command=$_.FullName}
            }
        } catch {}
    }
    # Auto-start services (non-Microsoft is interesting, but show all)
    try {
        Get-Service -EA SilentlyContinue | Where-Object {
            $_ -ne $null -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running'
        } | Select-Object -First 40 | ForEach-Object {
            $items += [PSCustomObject]@{Source='Auto Service'; Name=$_.DisplayName; Command=$_.Name}
        }
    } catch {}
    $items
}

function Get-ReliabilityInfo {
    try {
        Get-WinEvent -ProviderName 'Microsoft-Windows-Reliability-Analysis-Engine' -MaxEvents 200 -EA Stop |
            Where-Object { $_.Id -in @(1,2,3,4,10,11,12,14,20,26) } |
            Sort-Object TimeCreated -Descending |
            ForEach-Object {
                $type = switch($_.Id){
                    1  {'App Crash'}   2  {'App Hang'}  3  {'Driver Err'}
                    4  {'Misc Fail'}   10 {'System Fail'} 11 {'Boot Fail'}
                    12 {'OS Recover'}  14 {'Unplanned'}   20 {'Update Install'}
                    26 {'Inst Fail'}   default{'Event '+$_.Id}
                }
                [PSCustomObject]@{
                    Time    = $_.TimeCreated
                    Type    = $type
                    Source  = $_.ProviderName
                    Message = ($_.Message -split "`n")[0] -replace '\s+',' '
                    Id      = $_.Id
                }
            }
    } catch {
        # Fallback via WMI
        try {
            Get-CimInstance Win32_ReliabilityRecords -EA Stop | Sort-Object TimeGenerated -Descending |
                Select-Object -First 100 |
                ForEach-Object {
                    [PSCustomObject]@{
                        Time    = $_.TimeGenerated
                        Type    = $_.SourceName
                        Source  = $_.ProductName
                        Message = ($_.Message -split "`n")[0] -replace '\s+',' '
                        Id      = $_.RecordNumber
                    }
                }
        } catch { @() }
    }
}

function Get-ADHealthInfo {
    $sb = [System.Text.StringBuilder]::new()
    # Domain info
    $domain = $null
    try { $domain = (Get-CimInstance Win32_ComputerSystem).Domain } catch {}
    $isDomain = $domain -and $domain -notmatch 'WORKGROUP'
    $sb.AppendLine("═══ Domain / Workgroup ═══") | Out-Null
    $sb.AppendLine("  Domain : $domain") | Out-Null
    $sb.AppendLine("  Type   : $(if($isDomain){'Domain-Joined'}else{'Workgroup / Standalone'})") | Out-Null
    # Kerberos tickets
    $sb.AppendLine("`n═══ Kerberos Tickets (klist) ═══") | Out-Null
    try {
        $klist = & klist 2>&1 | Out-String
        $sb.AppendLine($klist) | Out-Null
    } catch { $sb.AppendLine("  klist not available") | Out-Null }
    # DC connectivity (only if domain-joined)
    if ($isDomain) {
        $sb.AppendLine("═══ Domain Controller Discovery ═══") | Out-Null
        try {
            $nltest = & nltest /dsgetdc:$domain /force 2>&1 | Out-String
            $sb.AppendLine($nltest) | Out-Null
        } catch { $sb.AppendLine("  nltest failed") | Out-Null }
        # SYSVOL/NETLOGON
        $sb.AppendLine("═══ SYSVOL / NETLOGON ═══") | Out-Null
        foreach ($share in @('SYSVOL','NETLOGON')) {
            $unc = "\\$domain\$share"
            $ok  = Test-Path $unc -EA SilentlyContinue
            $sb.AppendLine("  $($unc.PadRight(45)) $(if($ok){'REACHABLE'}else{'UNREACHABLE'})") | Out-Null
        }
    }
    # Time sync
    $sb.AppendLine("`n═══ Time Synchronization ═══") | Out-Null
    try {
        $w32 = & w32tm /query /status 2>&1 | Out-String
        $sb.AppendLine($w32) | Out-Null
    } catch { $sb.AppendLine("  w32tm not available") | Out-Null }
    $sb.ToString()
}

function Get-GPOInfo {
    try {
        $out = & gpresult /r /f 2>&1 | Out-String
        $out
    } catch { "gpresult failed: $_" }
}

function Get-iSCSIInfo {
    $sb = [System.Text.StringBuilder]::new()
    # iSCSI Sessions
    $sb.AppendLine("═══ iSCSI Sessions ═══") | Out-Null
    try {
        $sessions = Get-IscsiSession -EA Stop
        if ($sessions) {
            foreach ($s in $sessions) {
                $sb.AppendLine("  Target  : $($s.TargetNodeAddress)") | Out-Null
                $sb.AppendLine("  Initiator: $($s.InitiatorNodeAddress)") | Out-Null
                $sb.AppendLine("  Auth    : $($s.AuthenticationType)  |  Connected: $($s.IsConnected)") | Out-Null
                $sb.AppendLine("") | Out-Null
            }
        } else { $sb.AppendLine("  No active iSCSI sessions.") | Out-Null }
    } catch { $sb.AppendLine("  iSCSI not available: $_") | Out-Null }
    # MPIO
    $sb.AppendLine("═══ MPIO / Multipath ═══") | Out-Null
    try {
        $mpio = Get-MPIOSetting -EA Stop
        $sb.AppendLine("  PathVerification : $($mpio.PathVerificationState)") | Out-Null
        $sb.AppendLine("  PDORemovePeriod  : $($mpio.PDORemovePeriod)") | Out-Null
        $sb.AppendLine("  RetryCount       : $($mpio.RetryCount)") | Out-Null
        $sb.AppendLine("  RetryInterval    : $($mpio.RetryInterval)") | Out-Null
    } catch { $sb.AppendLine("  MPIO not installed or not elevated.") | Out-Null }
    # Physical Disks
    $sb.AppendLine("`n═══ Physical Disks ═══") | Out-Null
    try {
        $disks = Get-PhysicalDisk -EA Stop
        foreach ($d in $disks) {
            $sb.AppendLine("  [$($d.DeviceId)]  $($d.FriendlyName.PadRight(40))  $($d.MediaType.PadRight(8))  $([math]::Round($d.Size/1GB,1)) GB  $($d.HealthStatus)") | Out-Null
        }
    } catch {
        Get-CimInstance Win32_DiskDrive -EA SilentlyContinue | ForEach-Object {
            $sb.AppendLine("  [$($_.Index)]  $($_.Caption.PadRight(40))  $([math]::Round($_.Size/1GB,1)) GB  Status:$($_.Status)") | Out-Null
        }
    }
    # Disk Queue performance counter
    $sb.AppendLine("`n═══ Disk Queue Length (current) ═══") | Out-Null
    try {
        $queues = Get-Counter '\PhysicalDisk(*)\Current Disk Queue Length' -EA Stop
        foreach ($s in $queues.CounterSamples) {
            if ($s.InstanceName -ne '_total') {
                $sb.AppendLine("  $($s.InstanceName.PadRight(20))  Queue: $($s.CookedValue)") | Out-Null
            }
        }
    } catch { $sb.AppendLine("  (unable to read perf counters)") | Out-Null }
    $sb.ToString()
}

function Test-SSLEndpoint($hostname,$port=443) {
    $cert2 = $null; $errMsg = $null; $proto = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($hostname,$port,$null,$null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000,$false)) {
            $tcp.Close(); return @{OK=$false; Err="Connection timed out to $hostname`:$port"}
        }
        $tcp.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(),$false,{$true},$null)
        $ssl.AuthenticateAsClient($hostname)
        $proto = $ssl.SslProtocol
        $raw = $ssl.RemoteCertificate
        $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($raw)
        $ssl.Close(); $tcp.Close()
    } catch { $errMsg = $_.Exception.Message }
    if ($cert2) {
        $days = ($cert2.NotAfter - (Get-Date)).Days
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        [void]$chain.Build($cert2)
        $chainNames = $chain.ChainElements | ForEach-Object { ($_.Certificate.Subject -split ',')[0] -replace 'CN=','' }
        @{
            OK          = $true
            Subject     = $cert2.Subject
            Issuer      = $cert2.Issuer
            Thumbprint  = $cert2.Thumbprint
            NotBefore   = $cert2.NotBefore
            NotAfter    = $cert2.NotAfter
            DaysLeft    = $days
            Protocol    = $proto
            Chain       = $chainNames -join ' → '
            SANs        = (($cert2.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.17'}).Format($false))
        }
    } else {
        @{OK=$false; Err=$errMsg}
    }
}

function Get-ListeningPorts {
    $procMap = @{}
    Get-Process -EA SilentlyContinue | Where-Object {$_} | ForEach-Object {
        $path = try{$_.MainModule.FileName}catch{'—'}
        $procMap[$_.Id] = @{Name=$_.Name; Path=$path}
    }
    $rows = [System.Collections.Generic.List[PSObject]]::new()
    try {
        Get-NetTCPConnection -EA Stop | ForEach-Object {
            $p = $procMap[$_.OwningProcess]
            $rows.Add([PSCustomObject]@{
                Proto='TCP'; LocalAddr=$_.LocalAddress; Port=$_.LocalPort
                RemoteAddr=$_.RemoteAddress; RemotePort=$_.RemotePort
                State=$_.State; PID=$_.OwningProcess
                Process=if($p){$p.Name}else{'—'}; Path=if($p){$p.Path}else{'—'}
            })
        }
    } catch {}
    try {
        Get-NetUDPEndpoint -EA Stop | ForEach-Object {
            $p = $procMap[$_.OwningProcess]
            $rows.Add([PSCustomObject]@{
                Proto='UDP'; LocalAddr=$_.LocalAddress; Port=$_.LocalPort
                RemoteAddr='—'; RemotePort='—'; State='—'; PID=$_.OwningProcess
                Process=if($p){$p.Name}else{'—'}; Path=if($p){$p.Path}else{'—'}
            })
        }
    } catch {}
    $rows | Sort-Object Proto,Port
}

function Expand-IPRange([string]$input) {
    if ($input -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
        $parts = ($Matches[1] -split '\.') | ForEach-Object {[int]$_}
        $ipInt = ($parts[0] -shl 24) -bor ($parts[1] -shl 16) -bor ($parts[2] -shl 8) -bor $parts[3]
        $prefix = [int]$Matches[2]
        $size   = [math]::Pow(2, 32-$prefix)
        $mask   = -bnot([int]($size-1))
        $net    = $ipInt -band $mask
        1..([int]$size-2) | ForEach-Object {
            $a = $net + $_
            "$( ($a -shr 24) -band 255).$( ($a -shr 16) -band 255).$( ($a -shr 8) -band 255).$($a -band 255)"
        }
    } elseif ($input -match '^(\d+\.\d+\.\d+\.)(\d+)-(\d+)$') {
        [int]$Matches[2]..[int]$Matches[3] | ForEach-Object { "$($Matches[1])$_" }
    } else { @($input) }
}

function Get-ARPCache {
    try {
        Get-NetNeighbor -EA Stop | Where-Object {$_.State -ne 'Unreachable' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00'} |
            Select-Object InterfaceAlias,IPAddress,LinkLayerAddress,State |
            Sort-Object IPAddress
    } catch {
        & arp -a 2>&1 | Where-Object {$_ -match '^\s+(\d+\.\d+\.\d+\.\d+)'} | ForEach-Object {
            $t = ($_ -split '\s+') | Where-Object {$_}
            [PSCustomObject]@{InterfaceAlias='—';IPAddress=$t[0];LinkLayerAddress=$t[1];State=$t[2]}
        }
    }
}

function Get-DHCPInfo {
    Get-CimInstance Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
        Where-Object {$_.IPEnabled -and $_.DHCPEnabled} |
        Select-Object Description,
            @{N='IP';          E={$_.IPAddress -join ', '}},
            @{N='DHCP Server'; E={$_.DHCPServer}},
            @{N='Lease Obtained';E={$_.DHCPLeaseObtained}},
            @{N='Lease Expires'; E={$_.DHCPLeaseExpires}}
}

function Get-InstalledSoftware([string]$filter='') {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $all = $paths | ForEach-Object {
        Get-ItemProperty $_ -EA SilentlyContinue | Where-Object {$_.DisplayName} |
        Select-Object DisplayName,Publisher,DisplayVersion,
            @{N='Installed';E={$_.InstallDate}},
            @{N='Size(MB)'; E={if($_.EstimatedSize){[math]::Round($_.EstimatedSize/1KB,1)}else{''}}}
    } | Sort-Object DisplayName -Unique
    if ($filter) { $all | Where-Object {$_.DisplayName -like "*$filter*" -or $_.Publisher -like "*$filter*"} }
    else          { $all }
}

function Get-IISHealth {
    $r = @{Available=$false; Sites=@(); Pools=@()}
    try {
        Import-Module WebAdministration -EA Stop
        $r.Available = $true
        $r.Sites = Get-Website -EA Stop | Select-Object Name,State,PhysicalPath,
            @{N='Bindings';E={($_.Bindings.Collection|ForEach-Object{"$($_.Protocol)://$($_.bindingInformation.TrimStart(':'))"}) -join '  '}}
        $r.Pools = Get-ChildItem IIS:\AppPools -EA Stop | Select-Object Name,State,ManagedRuntimeVersion,
            @{N='Pipeline';E={$_.ManagedPipelineMode}},
            @{N='Identity';E={$_.ProcessModel.UserName}}
    } catch { $r.Available = $false }
    $r
}

function Get-WinActivation {
    try { & cscript //NoLogo "$env:SystemRoot\System32\slmgr.vbs" /dli 2>&1 | Out-String }
    catch { "slmgr not available: $_" }
}

function Get-PerCoreCPU {
    try {
        (Get-Counter '\Processor(*)\% Processor Time' -EA Stop).CounterSamples |
            Where-Object {$_.InstanceName -ne '_total'} |
            Sort-Object {[int]($_.InstanceName -replace '\D','')} |
            ForEach-Object { [PSCustomObject]@{Core="CPU $($_.InstanceName)"; 'Usage %'=[math]::Round($_.CookedValue,1)} }
    } catch { @() }
}

function Get-HandleLeaks {
    Get-Process -EA SilentlyContinue | Where-Object {$_} |
        Sort-Object HandleCount -Descending | Select-Object -First 35 |
        ForEach-Object {
            $gdi=0; $usr=0
            try { $gdi=[Win32GDI]::GetGuiResources($_.Handle,0); $usr=[Win32GDI]::GetGuiResources($_.Handle,1) } catch {}
            [PSCustomObject]@{
                Name=$_.Name; PID=$_.Id; Handles=$_.HandleCount
                GDI=$gdi; User=$usr; 'RAM(MB)'=[math]::Round($_.WorkingSet64/1MB,1)
                Path=try{$_.MainModule.FileName}catch{'—'}
            }
        }
}

function Get-NetBandwidth {
    try {
        $s = Get-Counter '\Network Interface(*)\Bytes Sent/sec',
                         '\Network Interface(*)\Bytes Received/sec' -EA Stop
        $h = @{}
        foreach ($c in $s.CounterSamples) {
            $n = $c.InstanceName; if($n -eq '_total'){continue}
            if(-not $h[$n]){$h[$n]=@{Name=$n;SendKBs=0;RecvKBs=0}}
            if($c.Path -match 'Sent')   {$h[$n].SendKBs=[math]::Round($c.CookedValue/1KB,1)}
            else                         {$h[$n].RecvKBs=[math]::Round($c.CookedValue/1KB,1)}
        }
        $h.Values | Sort-Object Name
    } catch { @() }
}

# ─── UI helpers ───────────────────────────────────────────────────────────────
function New-Grid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.BackgroundColor                           = $C.BgMid
    $g.ForeColor                                 = $C.White
    $g.GridColor                                 = $C.GridLine
    $g.BorderStyle                               = 'None'
    $g.DefaultCellStyle.BackColor                = $C.BgMid
    $g.DefaultCellStyle.ForeColor                = $C.White
    $g.DefaultCellStyle.SelectionBackColor       = [System.Drawing.Color]::FromArgb(0,100,150)
    $g.DefaultCellStyle.SelectionForeColor       = $C.White
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(27,27,44)
    $g.ColumnHeadersDefaultCellStyle.BackColor   = $C.BgCard
    $g.ColumnHeadersDefaultCellStyle.ForeColor   = $C.Accent
    $g.ColumnHeadersHeight                       = 28
    $g.RowHeadersVisible                         = $false
    $g.AllowUserToAddRows                        = $false
    $g.ReadOnly                                  = $true
    $g.SelectionMode                             = 'FullRowSelect'
    $g.MultiSelect                               = $false
    $g.AutoSizeColumnsMode                       = 'None'
    $g
}

function New-RTB($bg) {
    $r = New-Object System.Windows.Forms.RichTextBox
    $r.BackColor   = if($bg){$bg}else{$C.BgMid}
    $r.ForeColor   = [System.Drawing.Color]::FromArgb(200,210,230)
    $r.Font        = New-Object System.Drawing.Font('Consolas',9)
    $r.ReadOnly    = $true
    $r.BorderStyle = 'None'
    $r
}

function New-Btn($txt,$bg,$w=110,$h=28) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text=$txt; $b.Size=New-Object System.Drawing.Size($w,$h)
    $b.BackColor=$bg; $b.ForeColor=$C.White
    $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0
    $b
}

function New-TxtBox($ph,$x,$y,$w) {
    $t = New-Object System.Windows.Forms.TextBox
    if($ph){try{$t.PlaceholderText=$ph}catch{}}
    $t.Location=New-Object System.Drawing.Point($x,$y); $t.Width=$w
    $t.BackColor=[System.Drawing.Color]::FromArgb(38,38,60)
    $t.ForeColor=$C.White; $t.BorderStyle='FixedSingle'
    $t
}

function New-Combo($items,$x,$y,$w,$sel=0) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Items.AddRange($items); $c.SelectedIndex=$sel
    $c.Location=New-Object System.Drawing.Point($x,$y); $c.Width=$w
    $c.FlatStyle='Flat'; $c.BackColor=[System.Drawing.Color]::FromArgb(38,38,60)
    $c.ForeColor=$C.White; $c.DropDownStyle='DropDownList'
    $c
}

function New-Lbl($txt,$x,$y,$fc) {
    $l=New-Object System.Windows.Forms.Label; $l.Text=$txt
    $l.Location=New-Object System.Drawing.Point($x,$y); $l.AutoSize=$true
    $l.ForeColor=if($fc){$fc}else{$C.White}
    $l
}

function New-SecHdr($txt) {
    $l=New-Object System.Windows.Forms.Label; $l.Text="  $txt"
    $l.Dock='Top'; $l.Height=26; $l.ForeColor=$C.Accent; $l.BackColor=$C.BgBar
    $l.Font=New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
    $l.Padding=New-Object System.Windows.Forms.Padding(4,4,0,0)
    $l
}

function New-Card($title) {
    $p=New-Object System.Windows.Forms.Panel; $p.Size=New-Object System.Drawing.Size(245,118)
    $p.BackColor=$C.BgCard; $p.Margin=New-Object System.Windows.Forms.Padding(0,0,12,0)
    $lt=New-Object System.Windows.Forms.Label; $lt.Text=$title; $lt.ForeColor=$C.Accent
    $lt.Font=New-Object System.Drawing.Font('Segoe UI',9); $lt.Location=New-Object System.Drawing.Point(12,10); $lt.AutoSize=$true
    $lv=New-Object System.Windows.Forms.Label; $lv.Text='—'; $lv.ForeColor=$C.White; $lv.Tag='val'
    $lv.Font=New-Object System.Drawing.Font('Segoe UI',24,[System.Drawing.FontStyle]::Bold)
    $lv.Location=New-Object System.Drawing.Point(12,30); $lv.AutoSize=$true
    $ls=New-Object System.Windows.Forms.Label; $ls.Text='Loading…'; $ls.ForeColor=$C.Muted; $ls.Tag='sub'
    $ls.Font=New-Object System.Drawing.Font('Segoe UI',8); $ls.Location=New-Object System.Drawing.Point(12,84); $ls.AutoSize=$true
    $p.Controls.AddRange(@($lt,$lv,$ls)); $p
}

function Set-Card($card,$val,$sub,$color) {
    ($card.Controls|Where-Object Tag -eq 'val').Text=$val
    if($null -ne $color){ ($card.Controls|Where-Object Tag -eq 'val').ForeColor=$color }
    ($card.Controls|Where-Object Tag -eq 'sub').Text=$sub
}

function New-DT([string[]]$cols) {
    $dt=New-Object System.Data.DataTable
    foreach($c in $cols){[void]$dt.Columns.Add($c)}
    Write-Output -NoEnumerate $dt
}

# ─── FORM ─────────────────────────────────────────────────────────────────────
$form=New-Object System.Windows.Forms.Form
$form.Text='SRE Agent  —  Windows Diagnostics'
$form.Size=New-Object System.Drawing.Size(1250,860)
$form.MinimumSize=New-Object System.Drawing.Size(1050,720)
$form.StartPosition='CenterScreen'
$form.BackColor=$C.BgDark; $form.ForeColor=$C.White
$form.Font=New-Object System.Drawing.Font('Segoe UI',9)

# Title bar
$pnlTitle=New-Object System.Windows.Forms.Panel
$pnlTitle.Dock='Top'; $pnlTitle.Height=52; $pnlTitle.BackColor=$C.BgCard

$lblTitle=New-Object System.Windows.Forms.Label
$lblTitle.Text='  SRE Agent  |  Windows Diagnostics'
$lblTitle.ForeColor=$C.Accent; $lblTitle.Dock='Left'; $lblTitle.AutoSize=$true
$lblTitle.Font=New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Bold)
$lblTitle.Padding=New-Object System.Windows.Forms.Padding(12,10,0,0)

$lblHost=New-Object System.Windows.Forms.Label
$lblHost.Text="  $env:COMPUTERNAME  |  $env:USERNAME  "
$lblHost.ForeColor=$C.Muted; $lblHost.Dock='Right'; $lblHost.AutoSize=$true
$lblHost.Padding=New-Object System.Windows.Forms.Padding(0,16,16,0)

$btnWebSrv=New-Object System.Windows.Forms.Button
$btnWebSrv.Text='⬡ Web Dashboard'; $btnWebSrv.Dock='Right'
$btnWebSrv.Width=140; $btnWebSrv.BackColor=$C.DkGreen; $btnWebSrv.ForeColor=$C.White
$btnWebSrv.FlatStyle='Flat'; $btnWebSrv.FlatAppearance.BorderSize=0
$btnWebSrv.Font=New-Object System.Drawing.Font('Segoe UI',9)
$pnlTitle.Controls.AddRange(@($lblTitle,$lblHost,$btnWebSrv))

$tabs=New-Object System.Windows.Forms.TabControl
$tabs.Dock='Fill'; $tabs.Font=New-Object System.Drawing.Font('Segoe UI',9)
$tabs.Multiline=$true

$strip=New-Object System.Windows.Forms.StatusStrip; $strip.BackColor=$C.BgBar
$sLbl=New-Object System.Windows.Forms.ToolStripStatusLabel; $sLbl.ForeColor=$C.Muted; $sLbl.Text='Ready'
$strip.Items.Add($sLbl)|Out-Null

# ═══════════════════════════════════════════════════════════════════════════
# TAB 1 — SYSTEM HEALTH
# ═══════════════════════════════════════════════════════════════════════════
$tabH=New-Object System.Windows.Forms.TabPage; $tabH.Text='  System Health  '; $tabH.BackColor=$C.BgDark

$flowCards=New-Object System.Windows.Forms.FlowLayoutPanel
$flowCards.Dock='Top'; $flowCards.Height=138; $flowCards.BackColor=$C.BgDark
$flowCards.Padding=New-Object System.Windows.Forms.Padding(10,10,0,0)
$cCPU=New-Card 'CPU Usage'; $cMEM=New-Card 'Memory'; $cDSK=New-Card 'Disk C:'; $cGPU=New-Card 'GPU'
$flowCards.Controls.AddRange(@($cCPU,$cMEM,$cDSK,$cGPU))


$splitH=New-Object System.Windows.Forms.SplitContainer
$splitH.Dock='Fill'; $splitH.Orientation='Horizontal'; $splitH.SplitterDistance=220; $splitH.BackColor=$C.BgDark

$hProc=New-SecHdr 'Top Processes  (by CPU)'; $gProc=New-Grid; $gProc.Dock='Fill'
$splitH.Panel1.Controls.AddRange(@($gProc,$hProc))

$splitH2=New-Object System.Windows.Forms.SplitContainer
$splitH2.Dock='Fill'; $splitH2.Orientation='Vertical'; $splitH2.SplitterDistance=420; $splitH2.BackColor=$C.BgDark

$hDrv=New-SecHdr 'Drives'; $gDrv=New-Grid; $gDrv.Dock='Fill'; $gDrv.AutoSizeColumnsMode='Fill'
$splitH2.Panel1.Controls.AddRange(@($gDrv,$hDrv))

$hInfo=New-SecHdr 'GPU & Network'; $rtbInfo=New-RTB; $rtbInfo.Dock='Fill'
$splitH2.Panel2.Controls.AddRange(@($rtbInfo,$hInfo))
$splitH.Panel2.Controls.Add($splitH2)

$pnlHFoot=New-Object System.Windows.Forms.Panel; $pnlHFoot.Dock='Bottom'; $pnlHFoot.Height=38; $pnlHFoot.BackColor=$C.BgBar
$btnRefH=New-Btn 'Refresh Now' $C.Blue 108; $btnRefH.Location=New-Object System.Drawing.Point(10,5)
$chkAuto=New-Object System.Windows.Forms.CheckBox; $chkAuto.Text='Auto (30s)'; $chkAuto.Checked=$true
$chkAuto.ForeColor=$C.Muted; $chkAuto.AutoSize=$true; $chkAuto.Location=New-Object System.Drawing.Point(128,9)
$lblRefAt=New-Object System.Windows.Forms.Label; $lblRefAt.Text='Last refreshed: —'
$lblRefAt.ForeColor=$C.Muted; $lblRefAt.AutoSize=$true; $lblRefAt.Location=New-Object System.Drawing.Point(240,11)
$pnlHFoot.Controls.AddRange(@($btnRefH,$chkAuto,$lblRefAt))

$tabH.Controls.AddRange(@($pnlHFoot,$splitH,$flowCards))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 2 — EVENT VIEWER
# ═══════════════════════════════════════════════════════════════════════════
$tabEv=New-Object System.Windows.Forms.TabPage; $tabEv.Text='  Event Viewer  '; $tabEv.BackColor=$C.BgDark

$pnlEvF=New-Object System.Windows.Forms.Panel; $pnlEvF.Dock='Top'; $pnlEvF.Height=52; $pnlEvF.BackColor=$C.BgBar
$cmbEvLog  =New-Combo @('System','Application','Security','Setup','Microsoft-Windows-PowerShell/Operational') 45 14 272
$cmbEvLvl  =New-Combo @('All','Critical','Error','Warning','Information') 375 14 118
$numEvHrs  =New-Object System.Windows.Forms.NumericUpDown; $numEvHrs.Minimum=1; $numEvHrs.Maximum=720; $numEvHrs.Value=24
$numEvHrs.Location=New-Object System.Drawing.Point(590,14); $numEvHrs.Width=62
$numEvHrs.BackColor=[System.Drawing.Color]::FromArgb(38,38,60); $numEvHrs.ForeColor=$C.White
$txtEvSrch =New-TxtBox 'Search…' 665 14 195
$btnEvGo   =New-Btn 'Search' $C.Blue 75; $btnEvGo.Location=New-Object System.Drawing.Point(868,13)
$btnEvExp  =New-Btn 'Export CSV' $C.DkGreen 90; $btnEvExp.Location=New-Object System.Drawing.Point(951,13)
$pnlEvF.Controls.AddRange(@((New-Lbl 'Log:' 10 17 $C.Muted),(New-Lbl 'Level:' 330 17 $C.Muted),(New-Lbl 'Hrs:' 550 17 $C.Muted),
    $cmbEvLog,$cmbEvLvl,$numEvHrs,$txtEvSrch,$btnEvGo,$btnEvExp))

$lblEvCnt=New-Object System.Windows.Forms.Label; $lblEvCnt.Text='  Ready'; $lblEvCnt.Dock='Bottom'; $lblEvCnt.Height=24
$lblEvCnt.ForeColor=$C.Muted; $lblEvCnt.BackColor=$C.BgBar; $lblEvCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)

$splitEv=New-Object System.Windows.Forms.SplitContainer; $splitEv.Dock='Fill'
$splitEv.Orientation='Horizontal'; $splitEv.SplitterDistance=340; $splitEv.BackColor=$C.BgDark
$gEv=New-Grid; $gEv.Dock='Fill'
$rtbEvD=New-RTB; $rtbEvD.Dock='Fill'; $rtbEvD.Text='Select a row to view the full message.'
$splitEv.Panel1.Controls.Add($gEv); $splitEv.Panel2.Controls.Add($rtbEvD)
$tabEv.Controls.AddRange(@($lblEvCnt,$splitEv,$pnlEvF))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 3 — NETWORK
# ═══════════════════════════════════════════════════════════════════════════
$tabNet=New-Object System.Windows.Forms.TabPage; $tabNet.Text='  Network  '; $tabNet.BackColor=$C.BgDark

$pnlNB=New-Object System.Windows.Forms.Panel; $pnlNB.Dock='Top'; $pnlNB.Height=92; $pnlNB.BackColor=$C.BgBar

$pnlNR1=New-Object System.Windows.Forms.Panel; $pnlNR1.SetBounds(0,0,1250,46); $pnlNR1.BackColor=$C.BgBar
$txtNTgt=New-TxtBox '8.8.8.8 or hostname' 10 10 175
$btnNPing =New-Btn 'Ping'      $C.Blue 85;                              $btnNPing.Location =New-Object System.Drawing.Point(194,9)
$btnNTrc  =New-Btn 'Traceroute' ([System.Drawing.Color]::FromArgb(55,55,95)) 100; $btnNTrc.Location  =New-Object System.Drawing.Point(287,9)
$btnNAdp  =New-Btn 'Adapters'  ([System.Drawing.Color]::FromArgb(55,55,95)) 90;  $btnNAdp.Location  =New-Object System.Drawing.Point(395,9)
$btnNTCP  =New-Btn 'TCP Conn'  ([System.Drawing.Color]::FromArgb(55,55,95)) 90;  $btnNTCP.Location  =New-Object System.Drawing.Point(493,9)
$btnNDnsC =New-Btn 'DNS Cache' ([System.Drawing.Color]::FromArgb(55,55,95)) 90;  $btnNDnsC.Location =New-Object System.Drawing.Point(591,9)
$btnNRte  =New-Btn 'Route Table' ([System.Drawing.Color]::FromArgb(55,55,95)) 100; $btnNRte.Location =New-Object System.Drawing.Point(689,9)
$pnlNR1.Controls.AddRange(@($txtNTgt,$btnNPing,$btnNTrc,$btnNAdp,$btnNTCP,$btnNDnsC,$btnNRte))

$pnlNR2=New-Object System.Windows.Forms.Panel; $pnlNR2.SetBounds(0,46,1250,46); $pnlNR2.BackColor=$C.BgBar
$txtDNSNm =New-TxtBox 'Hostname to resolve' 90 10 120
$txtDNSSv =New-TxtBox 'DNS server (blank=default)' 218 10 205
$cmbDNST  =New-Combo @('A','AAAA','CNAME','MX','NS','PTR','SOA','SRV','TXT','ANY') 431 10 90
$btnDNSGo =New-Btn 'DNS Lookup' $C.Blue 100; $btnDNSGo.Location=New-Object System.Drawing.Point(529,9)
$pnlNR2.Controls.AddRange(@((New-Lbl 'DNS Lookup:' 3 14 $C.Muted),$txtDNSNm,$txtDNSSv,$cmbDNST,$btnDNSGo))

$pnlNB.Controls.AddRange(@($pnlNR1,$pnlNR2))
$rtbNet=New-RTB; $rtbNet.Dock='Fill'; $rtbNet.Text='Use the buttons above to run network diagnostics.'
$tabNet.Controls.AddRange(@($rtbNet,$pnlNB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 4 — PORT TESTING
# ═══════════════════════════════════════════════════════════════════════════
$tabPT=New-Object System.Windows.Forms.TabPage; $tabPT.Text='  Port Testing  '; $tabPT.BackColor=$C.BgDark

$pnlPTB=New-Object System.Windows.Forms.Panel; $pnlPTB.Dock='Top'; $pnlPTB.Height=92; $pnlPTB.BackColor=$C.BgBar

$pnlPR1=New-Object System.Windows.Forms.Panel; $pnlPR1.SetBounds(0,0,1250,46); $pnlPR1.BackColor=$C.BgBar
$txtPTgt=New-TxtBox 'Target host / IP' 10 10 185
$x=203
$script:pBtns=@{}
foreach ($preset in $PortPresets.Keys) {
    $short=($preset -split '/')[0].Trim()
    $b=New-Btn $short ([System.Drawing.Color]::FromArgb(60,55,110)) 105
    $b.Location=New-Object System.Drawing.Point($x,9); $b.Tag=$preset
    $pnlPR1.Controls.Add($b); $script:pBtns[$preset]=$b; $x+=112
}
$pnlPR1.Controls.Add($txtPTgt)

$pnlPR2=New-Object System.Windows.Forms.Panel; $pnlPR2.SetBounds(0,46,1250,46); $pnlPR2.BackColor=$C.BgBar
$txtCPort =New-TxtBox 'Custom ports e.g. 443,8080,3389' 60 12 203
$cmbCProto=New-Combo @('TCP','UDP') 273 12 75
$btnCTest =New-Btn 'Test Custom'  $C.Blue 110;                               $btnCTest.Location  =New-Object System.Drawing.Point(356,11)
$btnPTAll =New-Btn 'Run ALL Presets' ([System.Drawing.Color]::FromArgb(120,50,10)) 135; $btnPTAll.Location=New-Object System.Drawing.Point(474,11)
$btnPTClr =New-Btn 'Clear Results' ([System.Drawing.Color]::FromArgb(50,50,80)) 115; $btnPTClr.Location=New-Object System.Drawing.Point(617,11)
$pnlPR2.Controls.AddRange(@((New-Lbl 'Custom:' 3 15 $C.Muted),$txtCPort,$cmbCProto,$btnCTest,$btnPTAll,$btnPTClr))

$pnlPTB.Controls.AddRange(@($pnlPR1,$pnlPR2))

$gPT=New-Grid; $gPT.Dock='Fill'
foreach ($col in @('Target','Group','Service','Port','Protocol','Status','Latency(ms)')) { $gPT.Columns.Add($col,$col)|Out-Null }
$gPT.Columns['Target'].Width=145; $gPT.Columns['Group'].Width=115; $gPT.Columns['Service'].Width=155
$gPT.Columns['Port'].Width=60;   $gPT.Columns['Protocol'].Width=78; $gPT.Columns['Status'].Width=88
$gPT.Columns['Latency(ms)'].Width=95

$tabPT.Controls.AddRange(@($gPT,$pnlPTB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 5 — PERMISSIONS
# ═══════════════════════════════════════════════════════════════════════════
$tabPerm=New-Object System.Windows.Forms.TabPage; $tabPerm.Text='  Permissions  '; $tabPerm.BackColor=$C.BgDark

$subPerm=New-Object System.Windows.Forms.TabControl; $subPerm.Dock='Fill'
$subPerm.Font=New-Object System.Drawing.Font('Segoe UI',9)

# NTFS sub-tab
$stNTFS=New-Object System.Windows.Forms.TabPage; $stNTFS.Text='  NTFS  '; $stNTFS.BackColor=$C.BgDark
$pnlNF=New-Object System.Windows.Forms.Panel; $pnlNF.Dock='Top'; $pnlNF.Height=48; $pnlNF.BackColor=$C.BgBar
$txtNFPath=New-TxtBox '' 42 12 418; $txtNFPath.Text='C:\'
$btnNFBr  =New-Btn 'Browse…' ([System.Drawing.Color]::FromArgb(55,55,90)) 80; $btnNFBr.Location=New-Object System.Drawing.Point(468,11)
$btnNFGet =New-Btn 'Get-Acl' $C.Blue 80;                                    $btnNFGet.Location=New-Object System.Drawing.Point(556,11)
$btnNFIcl =New-Btn 'icacls'  ([System.Drawing.Color]::FromArgb(55,55,90)) 75; $btnNFIcl.Location=New-Object System.Drawing.Point(644,11)
$pnlNF.Controls.AddRange(@((New-Lbl 'Path:' 3 15 $C.Muted),$txtNFPath,$btnNFBr,$btnNFGet,$btnNFIcl))

$splitNF=New-Object System.Windows.Forms.SplitContainer; $splitNF.Dock='Fill'
$splitNF.Orientation='Vertical'; $splitNF.SplitterDistance=700; $splitNF.BackColor=$C.BgDark
$gNF=New-Grid; $gNF.Dock='Fill'; $gNF.AutoSizeColumnsMode='Fill'
$rtbNF=New-RTB; $rtbNF.Dock='Fill'; $rtbNF.Text='icacls raw output appears here.'
$splitNF.Panel1.Controls.Add($gNF); $splitNF.Panel2.Controls.Add($rtbNF)
$stNTFS.Controls.AddRange(@($splitNF,$pnlNF))

# Shares sub-tab
$stShr=New-Object System.Windows.Forms.TabPage; $stShr.Text='  Shares  '; $stShr.BackColor=$C.BgDark
$pnlShrB=New-Object System.Windows.Forms.Panel; $pnlShrB.Dock='Top'; $pnlShrB.Height=48; $pnlShrB.BackColor=$C.BgBar
$btnShrLoad=New-Btn 'List Shares' $C.Blue 110; $btnShrLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlShrB.Controls.AddRange(@($btnShrLoad,(New-Lbl 'Click a share row to view its permissions' 130 14 $C.Muted)))

$splitShr=New-Object System.Windows.Forms.SplitContainer; $splitShr.Dock='Fill'
$splitShr.Orientation='Vertical'; $splitShr.SplitterDistance=500; $splitShr.BackColor=$C.BgDark
$gShr=New-Grid; $gShr.Dock='Fill'; $gShr.AutoSizeColumnsMode='Fill'
$hShrP=New-SecHdr 'Share Permissions'; $gShrP=New-Grid; $gShrP.Dock='Fill'; $gShrP.AutoSizeColumnsMode='Fill'
$splitShr.Panel1.Controls.Add($gShr); $splitShr.Panel2.Controls.AddRange(@($gShrP,$hShrP))
$stShr.Controls.AddRange(@($splitShr,$pnlShrB))

# Access Test sub-tab
$stAcc=New-Object System.Windows.Forms.TabPage; $stAcc.Text='  Access Test  '; $stAcc.BackColor=$C.BgDark
$pnlAccB=New-Object System.Windows.Forms.Panel; $pnlAccB.Dock='Top'; $pnlAccB.Height=88; $pnlAccB.BackColor=$C.BgBar
$txtAccP=New-TxtBox '' 42 12 418; $txtAccP.Text='C:\'
$btnAccBr=New-Btn 'Browse…' ([System.Drawing.Color]::FromArgb(55,55,90)) 80; $btnAccBr.Location=New-Object System.Drawing.Point(468,11)
$btnAccT =New-Btn 'Test Access' $C.Blue 110; $btnAccT.Location=New-Object System.Drawing.Point(10,48)
$pnlAccB.Controls.AddRange(@((New-Lbl 'Path:' 3 15 $C.Muted),$txtAccP,$btnAccBr,$btnAccT))
$rtbAcc=New-RTB; $rtbAcc.Dock='Fill'; $rtbAcc.Text='Browse to a path and click Test Access.'
$stAcc.Controls.AddRange(@($rtbAcc,$pnlAccB))

# User Groups sub-tab
$stGrp=New-Object System.Windows.Forms.TabPage; $stGrp.Text='  User Groups  '; $stGrp.BackColor=$C.BgDark
$pnlGrpB=New-Object System.Windows.Forms.Panel; $pnlGrpB.Dock='Top'; $pnlGrpB.Height=48; $pnlGrpB.BackColor=$C.BgBar
$btnGrpLoad=New-Btn 'Load My Groups' $C.Blue 130; $btnGrpLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlGrpB.Controls.Add($btnGrpLoad)
$rtbGrp=New-RTB; $rtbGrp.Dock='Fill'; $rtbGrp.Text='Click "Load My Groups" to enumerate your token groups.'
$stGrp.Controls.AddRange(@($rtbGrp,$pnlGrpB))

$subPerm.TabPages.AddRange(@($stNTFS,$stShr,$stAcc,$stGrp))
$tabPerm.Controls.Add($subPerm)

# ═══════════════════════════════════════════════════════════════════════════
# TAB 6 — SERVICES
# ═══════════════════════════════════════════════════════════════════════════
$tabSvc=New-Object System.Windows.Forms.TabPage; $tabSvc.Text='  Services  '; $tabSvc.BackColor=$C.BgDark

$pnlSvcB=New-Object System.Windows.Forms.Panel; $pnlSvcB.Dock='Top'; $pnlSvcB.Height=48; $pnlSvcB.BackColor=$C.BgBar
$txtSvcF  =New-TxtBox 'Filter name…' 48 13 182
$cmbSvcSt =New-Combo @('All','Running','Stopped') 238 13 105
$btnSvcRef=New-Btn 'Refresh'  $C.Blue 85;       $btnSvcRef.Location=New-Object System.Drawing.Point(351,11)
$btnSvcSta=New-Btn 'Start'    $C.DkGreen 80;    $btnSvcSta.Location=New-Object System.Drawing.Point(444,11)
$btnSvcStp=New-Btn 'Stop'     $C.DkRed 80;      $btnSvcStp.Location=New-Object System.Drawing.Point(532,11)
$btnSvcRst=New-Btn 'Restart'  $C.DkOrange 90;   $btnSvcRst.Location=New-Object System.Drawing.Point(620,11)
$pnlSvcB.Controls.AddRange(@((New-Lbl 'Filter:' 3 16 $C.Muted),$txtSvcF,$cmbSvcSt,$btnSvcRef,$btnSvcSta,$btnSvcStp,$btnSvcRst))

$lblSvcCnt=New-Object System.Windows.Forms.Label; $lblSvcCnt.Text='  —'; $lblSvcCnt.Dock='Bottom'; $lblSvcCnt.Height=24
$lblSvcCnt.ForeColor=$C.Muted; $lblSvcCnt.BackColor=$C.BgBar; $lblSvcCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)

$gSvc=New-Grid; $gSvc.Dock='Fill'
$tabSvc.Controls.AddRange(@($lblSvcCnt,$gSvc,$pnlSvcB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 7 — SECURITY
# ═══════════════════════════════════════════════════════════════════════════
$tabSec=New-Object System.Windows.Forms.TabPage; $tabSec.Text='  Security  '; $tabSec.BackColor=$C.BgDark

$pnlSecB=New-Object System.Windows.Forms.Panel; $pnlSecB.Dock='Top'; $pnlSecB.Height=48; $pnlSecB.BackColor=$C.BgBar
$btnSecLoad=New-Btn 'Load Security Info' $C.Blue 145; $btnSecLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlSecB.Controls.Add($btnSecLoad)

$splitSec=New-Object System.Windows.Forms.SplitContainer; $splitSec.Dock='Fill'
$splitSec.Orientation='Vertical'; $splitSec.SplitterDistance=500; $splitSec.BackColor=$C.BgDark

$rtbSec=New-RTB; $rtbSec.Dock='Fill'; $rtbSec.Text='Click "Load Security Info" to begin.'

$splitSec2=New-Object System.Windows.Forms.SplitContainer; $splitSec2.Dock='Fill'
$splitSec2.Orientation='Horizontal'; $splitSec2.SplitterDistance=310; $splitSec2.BackColor=$C.BgDark
$hUsers=New-SecHdr 'Local Users'; $gUsers=New-Grid; $gUsers.Dock='Fill'; $gUsers.AutoSizeColumnsMode='Fill'
$splitSec2.Panel1.Controls.AddRange(@($gUsers,$hUsers))
$hGrps=New-SecHdr 'Local Groups'; $gGrps=New-Grid; $gGrps.Dock='Fill'; $gGrps.AutoSizeColumnsMode='Fill'
$splitSec2.Panel2.Controls.AddRange(@($gGrps,$hGrps))

$splitSec.Panel1.Controls.Add($rtbSec); $splitSec.Panel2.Controls.Add($splitSec2)
$tabSec.Controls.AddRange(@($splitSec,$pnlSecB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 8 — SYSTEM INFO
# ═══════════════════════════════════════════════════════════════════════════
$tabSI=New-Object System.Windows.Forms.TabPage; $tabSI.Text='  System Info  '; $tabSI.BackColor=$C.BgDark
$pnlSIB=New-Object System.Windows.Forms.Panel; $pnlSIB.Dock='Top'; $pnlSIB.Height=48; $pnlSIB.BackColor=$C.BgBar
$btnSILoad=New-Btn 'Load Info' $C.Blue 110; $btnSILoad.Location=New-Object System.Drawing.Point(10,10)
$pnlSIB.Controls.Add($btnSILoad)
$rtbSI=New-RTB; $rtbSI.Dock='Fill'
$tabSI.Controls.AddRange(@($rtbSI,$pnlSIB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 9 — WINDOWS UPDATES
# ═══════════════════════════════════════════════════════════════════════════
$tabUpd=New-Object System.Windows.Forms.TabPage; $tabUpd.Text='  Updates  '; $tabUpd.BackColor=$C.BgDark
$pnlUpdB=New-Object System.Windows.Forms.Panel; $pnlUpdB.Dock='Top'; $pnlUpdB.Height=48; $pnlUpdB.BackColor=$C.BgBar
$btnUpdHist=New-Btn 'Update History' $C.Blue 130; $btnUpdHist.Location=New-Object System.Drawing.Point(10,10)
$btnUpdPend=New-Btn 'Check Pending' ([System.Drawing.Color]::FromArgb(120,80,0)) 130; $btnUpdPend.Location=New-Object System.Drawing.Point(148,10)
$lblUpdNote=New-Lbl '(Pending scan may take ~30s)' 290 17 $C.Muted
$pnlUpdB.Controls.AddRange(@($btnUpdHist,$btnUpdPend,$lblUpdNote))
$lblUpdCnt=New-Object System.Windows.Forms.Label; $lblUpdCnt.Text='  —'; $lblUpdCnt.Dock='Bottom'; $lblUpdCnt.Height=24
$lblUpdCnt.ForeColor=$C.Muted; $lblUpdCnt.BackColor=$C.BgBar; $lblUpdCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$gUpd=New-Grid; $gUpd.Dock='Fill'
$tabUpd.Controls.AddRange(@($lblUpdCnt,$gUpd,$pnlUpdB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 10 — CERTIFICATES
# ═══════════════════════════════════════════════════════════════════════════
$tabCert=New-Object System.Windows.Forms.TabPage; $tabCert.Text='  Certificates  '; $tabCert.BackColor=$C.BgDark
$pnlCertB=New-Object System.Windows.Forms.Panel; $pnlCertB.Dock='Top'; $pnlCertB.Height=48; $pnlCertB.BackColor=$C.BgBar
$btnCertScan=New-Btn 'Scan Cert Stores' $C.Blue 145; $btnCertScan.Location=New-Object System.Drawing.Point(10,10)
$cmbCertFilter=New-Combo @('All','OK','EXPIRING','EXPIRED') 165 10 110
$pnlCertB.Controls.AddRange(@($btnCertScan,$cmbCertFilter,(New-Lbl 'Filter:' 162 17 $C.Muted)))
$lblCertCnt=New-Object System.Windows.Forms.Label; $lblCertCnt.Text='  —'; $lblCertCnt.Dock='Bottom'; $lblCertCnt.Height=24
$lblCertCnt.ForeColor=$C.Muted; $lblCertCnt.BackColor=$C.BgBar; $lblCertCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$gCert=New-Grid; $gCert.Dock='Fill'
foreach($col in @('Store','Subject','Issuer','Expires','DaysLeft','Status','Thumbprint')){$gCert.Columns.Add($col,$col)|Out-Null}
$gCert.Columns['Store'].Width=95; $gCert.Columns['Subject'].Width=220; $gCert.Columns['Issuer'].Width=185
$gCert.Columns['Expires'].Width=145; $gCert.Columns['DaysLeft'].Width=70; $gCert.Columns['Status'].Width=85
$gCert.Columns['Thumbprint'].Width=160
$tabCert.Controls.AddRange(@($lblCertCnt,$gCert,$pnlCertB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 11 — SCHEDULED TASKS
# ═══════════════════════════════════════════════════════════════════════════
$tabTask=New-Object System.Windows.Forms.TabPage; $tabTask.Text='  Sched. Tasks  '; $tabTask.BackColor=$C.BgDark
$pnlTaskB=New-Object System.Windows.Forms.Panel; $pnlTaskB.Dock='Top'; $pnlTaskB.Height=48; $pnlTaskB.BackColor=$C.BgBar
$btnTaskLoad=New-Btn 'Load Tasks' $C.Blue 110; $btnTaskLoad.Location=New-Object System.Drawing.Point(10,10)
$cmbTaskFilter=New-Combo @('All','Failed','Running','Disabled') 130 10 110
$pnlTaskB.Controls.AddRange(@($btnTaskLoad,$cmbTaskFilter,(New-Lbl 'Filter:' 127 17 $C.Muted)))
$lblTaskCnt=New-Object System.Windows.Forms.Label; $lblTaskCnt.Text='  —'; $lblTaskCnt.Dock='Bottom'; $lblTaskCnt.Height=24
$lblTaskCnt.ForeColor=$C.Muted; $lblTaskCnt.BackColor=$C.BgBar; $lblTaskCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$gTask=New-Grid; $gTask.Dock='Fill'
foreach($col in @('Name','Path','State','Last Run','Next Run','Last Result')){$gTask.Columns.Add($col,$col)|Out-Null}
$gTask.Columns['Name'].Width=210; $gTask.Columns['Path'].Width=175; $gTask.Columns['State'].Width=80
$gTask.Columns['Last Run'].Width=148; $gTask.Columns['Next Run'].Width=148; $gTask.Columns['Last Result'].Width=100
$tabTask.Controls.AddRange(@($lblTaskCnt,$gTask,$pnlTaskB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 12 — STARTUP / AUTORUNS
# ═══════════════════════════════════════════════════════════════════════════
$tabAuto=New-Object System.Windows.Forms.TabPage; $tabAuto.Text='  Startup  '; $tabAuto.BackColor=$C.BgDark
$pnlAutoB=New-Object System.Windows.Forms.Panel; $pnlAutoB.Dock='Top'; $pnlAutoB.Height=48; $pnlAutoB.BackColor=$C.BgBar
$btnAutoLoad=New-Btn 'Scan Autoruns' $C.Blue 130; $btnAutoLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlAutoB.Controls.Add($btnAutoLoad)
$lblAutoCnt=New-Object System.Windows.Forms.Label; $lblAutoCnt.Text='  —'; $lblAutoCnt.Dock='Bottom'; $lblAutoCnt.Height=24
$lblAutoCnt.ForeColor=$C.Muted; $lblAutoCnt.BackColor=$C.BgBar; $lblAutoCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$gAuto=New-Grid; $gAuto.Dock='Fill'
foreach($col in @('Source','Name','Command')){$gAuto.Columns.Add($col,$col)|Out-Null}
$gAuto.Columns['Source'].Width=140; $gAuto.Columns['Name'].Width=210; $gAuto.Columns['Command'].Width=700
$tabAuto.Controls.AddRange(@($lblAutoCnt,$gAuto,$pnlAutoB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 13 — RELIABILITY MONITOR
# ═══════════════════════════════════════════════════════════════════════════
$tabRel=New-Object System.Windows.Forms.TabPage; $tabRel.Text='  Reliability  '; $tabRel.BackColor=$C.BgDark
$pnlRelB=New-Object System.Windows.Forms.Panel; $pnlRelB.Dock='Top'; $pnlRelB.Height=48; $pnlRelB.BackColor=$C.BgBar
$btnRelLoad=New-Btn 'Load Events' $C.Blue 110; $btnRelLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlRelB.Controls.Add($btnRelLoad)
$splitRel=New-Object System.Windows.Forms.SplitContainer; $splitRel.Dock='Fill'
$splitRel.Orientation='Horizontal'; $splitRel.SplitterDistance=320; $splitRel.BackColor=$C.BgDark
$gRel=New-Grid; $gRel.Dock='Fill'
foreach($col in @('Time','Type','Source','Message')){$gRel.Columns.Add($col,$col)|Out-Null}
$gRel.Columns['Time'].Width=148; $gRel.Columns['Type'].Width=115; $gRel.Columns['Source'].Width=160; $gRel.Columns['Message'].Width=700
$rtbRel=New-RTB; $rtbRel.Dock='Fill'; $rtbRel.Text='Select a row to view the full message.'
$splitRel.Panel1.Controls.Add($gRel); $splitRel.Panel2.Controls.Add($rtbRel)
$tabRel.Controls.AddRange(@($splitRel,$pnlRelB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 14 — AD / KERBEROS
# ═══════════════════════════════════════════════════════════════════════════
$tabAD=New-Object System.Windows.Forms.TabPage; $tabAD.Text='  AD / Kerberos  '; $tabAD.BackColor=$C.BgDark
$pnlADB=New-Object System.Windows.Forms.Panel; $pnlADB.Dock='Top'; $pnlADB.Height=48; $pnlADB.BackColor=$C.BgBar
$btnADLoad=New-Btn 'Run AD Checks' $C.Blue 130; $btnADLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlADB.Controls.Add($btnADLoad)
$rtbAD=New-RTB; $rtbAD.Dock='Fill'; $rtbAD.Text='Click "Run AD Checks" to query domain, Kerberos tickets, DC connectivity, and time sync.'
$tabAD.Controls.AddRange(@($rtbAD,$pnlADB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 15 — GROUP POLICY
# ═══════════════════════════════════════════════════════════════════════════
$tabGPO=New-Object System.Windows.Forms.TabPage; $tabGPO.Text='  Group Policy  '; $tabGPO.BackColor=$C.BgDark
$pnlGPOB=New-Object System.Windows.Forms.Panel; $pnlGPOB.Dock='Top'; $pnlGPOB.Height=48; $pnlGPOB.BackColor=$C.BgBar
$btnGPOLoad=New-Btn 'Run gpresult' $C.Blue 125; $btnGPOLoad.Location=New-Object System.Drawing.Point(10,10)
$btnGPOComp=New-Btn 'Computer Scope' ([System.Drawing.Color]::FromArgb(55,55,95)) 125; $btnGPOComp.Location=New-Object System.Drawing.Point(143,10)
$pnlGPOB.Controls.AddRange(@($btnGPOLoad,$btnGPOComp))
$rtbGPO=New-RTB; $rtbGPO.Dock='Fill'; $rtbGPO.Text='Click "Run gpresult" for user-scoped GPOs, or "Computer Scope" for machine GPOs (may need elevation).'
$tabGPO.Controls.AddRange(@($rtbGPO,$pnlGPOB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 16 — iSCSI / STORAGE
# ═══════════════════════════════════════════════════════════════════════════
$tabISCSI=New-Object System.Windows.Forms.TabPage; $tabISCSI.Text='  iSCSI / Storage  '; $tabISCSI.BackColor=$C.BgDark
$pnlISCSIB=New-Object System.Windows.Forms.Panel; $pnlISCSIB.Dock='Top'; $pnlISCSIB.Height=48; $pnlISCSIB.BackColor=$C.BgBar
$btnISCSILoad=New-Btn 'Load Storage Info' $C.Blue 145; $btnISCSILoad.Location=New-Object System.Drawing.Point(10,10)
$pnlISCSIB.Controls.Add($btnISCSILoad)
$rtbISCSI=New-RTB; $rtbISCSI.Dock='Fill'; $rtbISCSI.Text='Click "Load Storage Info" to query iSCSI sessions, MPIO settings, physical disks, and queue lengths.'
$tabISCSI.Controls.AddRange(@($rtbISCSI,$pnlISCSIB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 17 — SSL/TLS CHECKER
# ═══════════════════════════════════════════════════════════════════════════
$tabSSL=New-Object System.Windows.Forms.TabPage; $tabSSL.Text='  SSL/TLS  '; $tabSSL.BackColor=$C.BgDark
$pnlSSLB=New-Object System.Windows.Forms.Panel; $pnlSSLB.Dock='Top'; $pnlSSLB.Height=52; $pnlSSLB.BackColor=$C.BgBar
$txtSSLHost=New-TxtBox 'hostname or IP' 10 14 220
$numSSLPort=New-Object System.Windows.Forms.NumericUpDown; $numSSLPort.Minimum=1; $numSSLPort.Maximum=65535; $numSSLPort.Value=443
$numSSLPort.Location=New-Object System.Drawing.Point(238,14); $numSSLPort.Width=72
$numSSLPort.BackColor=[System.Drawing.Color]::FromArgb(38,38,60); $numSSLPort.ForeColor=$C.White
$btnSSLCheck=New-Btn 'Check TLS' $C.Blue 100; $btnSSLCheck.Location=New-Object System.Drawing.Point(318,13)
$pnlSSLB.Controls.AddRange(@((New-Lbl 'Host:' 5 17 $C.Muted),$txtSSLHost,(New-Lbl 'Port:' 234 17 $C.Muted),$numSSLPort,$btnSSLCheck))
$rtbSSL=New-RTB; $rtbSSL.Dock='Fill'; $rtbSSL.Text='Enter a hostname and port, then click Check TLS.'
$tabSSL.Controls.AddRange(@($rtbSSL,$pnlSSLB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 18 — LISTENING PORTS
# ═══════════════════════════════════════════════════════════════════════════
$tabLP=New-Object System.Windows.Forms.TabPage; $tabLP.Text='  Listening Ports  '; $tabLP.BackColor=$C.BgDark
$pnlLPB=New-Object System.Windows.Forms.Panel; $pnlLPB.Dock='Top'; $pnlLPB.Height=48; $pnlLPB.BackColor=$C.BgBar
$btnLPLoad =New-Btn 'Refresh' $C.Blue 90;                   $btnLPLoad.Location =New-Object System.Drawing.Point(10,10)
$cmbLPProto=New-Combo @('All','TCP','UDP') 108 10 80
$txtLPSrch =New-TxtBox 'Filter process/port…' 198 12 180
$btnLPSrch =New-Btn 'Filter' $C.DkPurple 75;                $btnLPSrch.Location =New-Object System.Drawing.Point(386,10)
$lblLPCnt  =New-Object System.Windows.Forms.Label; $lblLPCnt.Text='  —'; $lblLPCnt.Dock='Bottom'; $lblLPCnt.Height=24
$lblLPCnt.ForeColor=$C.Muted; $lblLPCnt.BackColor=$C.BgBar; $lblLPCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$pnlLPB.Controls.AddRange(@($btnLPLoad,$cmbLPProto,(New-Lbl 'Proto:' 104 17 $C.Muted),$txtLPSrch,$btnLPSrch))
$gLP=New-Grid; $gLP.Dock='Fill'
foreach($c in @('Proto','Local Addr','Port','Remote Addr','Rem Port','State','PID','Process','Path')){$gLP.Columns.Add($c,$c)|Out-Null}
$gLP.Columns['Proto'].Width=50; $gLP.Columns['Local Addr'].Width=130; $gLP.Columns['Port'].Width=58
$gLP.Columns['Remote Addr'].Width=130; $gLP.Columns['Rem Port'].Width=70; $gLP.Columns['State'].Width=110
$gLP.Columns['PID'].Width=52; $gLP.Columns['Process'].Width=140; $gLP.Columns['Path'].Width=480
$tabLP.Controls.AddRange(@($lblLPCnt,$gLP,$pnlLPB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 19 — PING SWEEP
# ═══════════════════════════════════════════════════════════════════════════
$tabPS=New-Object System.Windows.Forms.TabPage; $tabPS.Text='  Ping Sweep  '; $tabPS.BackColor=$C.BgDark
$pnlPSB=New-Object System.Windows.Forms.Panel; $pnlPSB.Dock='Top'; $pnlPSB.Height=52; $pnlPSB.BackColor=$C.BgBar
$txtPSRange=New-TxtBox '192.168.1.0/24  or  10.0.0.1-50' 56 14 252
$numPSTo   =New-Object System.Windows.Forms.NumericUpDown; $numPSTo.Minimum=100; $numPSTo.Maximum=5000; $numPSTo.Value=800
$numPSTo.Location=New-Object System.Drawing.Point(428,14); $numPSTo.Width=68
$numPSTo.BackColor=[System.Drawing.Color]::FromArgb(38,38,60); $numPSTo.ForeColor=$C.White
$btnPSSweep=New-Btn 'Sweep' $C.Blue 85;         $btnPSSweep.Location=New-Object System.Drawing.Point(504,13)
$btnPSStop =New-Btn 'Stop'  $C.DkRed 75;        $btnPSStop.Location =New-Object System.Drawing.Point(597,13); $btnPSStop.Enabled=$false
$pnlPSB.Controls.AddRange(@((New-Lbl 'Range:' 5 17 $C.Muted),$txtPSRange,(New-Lbl 'Timeout(ms):' 316 17 $C.Muted),$numPSTo,$btnPSSweep,$btnPSStop))
$lblPSCnt=New-Object System.Windows.Forms.Label; $lblPSCnt.Text='  —'; $lblPSCnt.Dock='Bottom'; $lblPSCnt.Height=24
$lblPSCnt.ForeColor=$C.Muted; $lblPSCnt.BackColor=$C.BgBar; $lblPSCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$gPS=New-Grid; $gPS.Dock='Fill'
foreach($c in @('IP','Status','RTT(ms)','Hostname')){$gPS.Columns.Add($c,$c)|Out-Null}
$gPS.Columns['IP'].Width=145; $gPS.Columns['Status'].Width=90; $gPS.Columns['RTT(ms)'].Width=80; $gPS.Columns['Hostname'].Width=340
$tabPS.Controls.AddRange(@($lblPSCnt,$gPS,$pnlPSB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 20 — NET DETAILS (ARP + DHCP)
# ═══════════════════════════════════════════════════════════════════════════
$tabND=New-Object System.Windows.Forms.TabPage; $tabND.Text='  Net Details  '; $tabND.BackColor=$C.BgDark
$pnlNDB=New-Object System.Windows.Forms.Panel; $pnlNDB.Dock='Top'; $pnlNDB.Height=48; $pnlNDB.BackColor=$C.BgBar
$btnNDLoad=New-Btn 'Load ARP + DHCP' $C.Blue 145; $btnNDLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlNDB.Controls.Add($btnNDLoad)
$splitND=New-Object System.Windows.Forms.SplitContainer; $splitND.Dock='Fill'
$splitND.Orientation='Horizontal'; $splitND.SplitterDistance=360; $splitND.BackColor=$C.BgDark
$hARP=New-SecHdr 'ARP Cache  (IP → MAC)'; $gARP=New-Grid; $gARP.Dock='Fill'; $gARP.AutoSizeColumnsMode='Fill'
$splitND.Panel1.Controls.AddRange(@($gARP,$hARP))
$hDHCP=New-SecHdr 'DHCP Leases'; $gDHCP=New-Grid; $gDHCP.Dock='Fill'; $gDHCP.AutoSizeColumnsMode='Fill'
$splitND.Panel2.Controls.AddRange(@($gDHCP,$hDHCP))
$tabND.Controls.AddRange(@($splitND,$pnlNDB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 21 — INSTALLED SOFTWARE
# ═══════════════════════════════════════════════════════════════════════════
$tabIS=New-Object System.Windows.Forms.TabPage; $tabIS.Text='  Software  '; $tabIS.BackColor=$C.BgDark
$pnlISB=New-Object System.Windows.Forms.Panel; $pnlISB.Dock='Top'; $pnlISB.Height=48; $pnlISB.BackColor=$C.BgBar
$txtISF  =New-TxtBox 'Filter name / publisher…' 10 13 220
$btnISLoad=New-Btn 'Load' $C.Blue 75;  $btnISLoad.Location=New-Object System.Drawing.Point(238,10)
$btnISSrch=New-Btn 'Filter' $C.DkPurple 75; $btnISSrch.Location=New-Object System.Drawing.Point(321,10)
$lblISCnt=New-Object System.Windows.Forms.Label; $lblISCnt.Text='  —'; $lblISCnt.Dock='Bottom'; $lblISCnt.Height=24
$lblISCnt.ForeColor=$C.Muted; $lblISCnt.BackColor=$C.BgBar; $lblISCnt.Font=New-Object System.Drawing.Font('Segoe UI',8)
$pnlISB.Controls.AddRange(@($txtISF,$btnISLoad,$btnISSrch))
$gIS=New-Grid; $gIS.Dock='Fill'
foreach($c in @('Name','Publisher','Version','Installed','Size(MB)')){$gIS.Columns.Add($c,$c)|Out-Null}
$gIS.Columns['Name'].Width=310; $gIS.Columns['Publisher'].Width=215; $gIS.Columns['Version'].Width=105
$gIS.Columns['Installed'].Width=90; $gIS.Columns['Size(MB)'].Width=80
$tabIS.Controls.AddRange(@($lblISCnt,$gIS,$pnlISB))

# ═══════════════════════════════════════════════════════════════════════════
# TAB 22 — IIS / ACTIVATION
# ═══════════════════════════════════════════════════════════════════════════
$tabIIS=New-Object System.Windows.Forms.TabPage; $tabIIS.Text='  IIS / Activation  '; $tabIIS.BackColor=$C.BgDark
$subIIS=New-Object System.Windows.Forms.TabControl; $subIIS.Dock='Fill'
$subIIS.Font=New-Object System.Drawing.Font('Segoe UI',9)
# IIS sub-tab
$stIIS=New-Object System.Windows.Forms.TabPage; $stIIS.Text='  IIS  '; $stIIS.BackColor=$C.BgDark
$pnlIISB=New-Object System.Windows.Forms.Panel; $pnlIISB.Dock='Top'; $pnlIISB.Height=48; $pnlIISB.BackColor=$C.BgBar
$btnIISLoad=New-Btn 'Load IIS' $C.Blue 100; $btnIISLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlIISB.Controls.Add($btnIISLoad)
$splitIIS=New-Object System.Windows.Forms.SplitContainer; $splitIIS.Dock='Fill'
$splitIIS.Orientation='Horizontal'; $splitIIS.SplitterDistance=280; $splitIIS.BackColor=$C.BgDark
$hSites=New-SecHdr 'Sites'; $gSites=New-Grid; $gSites.Dock='Fill'; $gSites.AutoSizeColumnsMode='Fill'
$splitIIS.Panel1.Controls.AddRange(@($gSites,$hSites))
$hPools=New-SecHdr 'Application Pools'; $gPools=New-Grid; $gPools.Dock='Fill'; $gPools.AutoSizeColumnsMode='Fill'
$splitIIS.Panel2.Controls.AddRange(@($gPools,$hPools))
$stIIS.Controls.AddRange(@($splitIIS,$pnlIISB))
# Activation sub-tab
$stAct=New-Object System.Windows.Forms.TabPage; $stAct.Text='  Windows Activation  '; $stAct.BackColor=$C.BgDark
$pnlActB=New-Object System.Windows.Forms.Panel; $pnlActB.Dock='Top'; $pnlActB.Height=48; $pnlActB.BackColor=$C.BgBar
$btnActLoad=New-Btn 'Run slmgr /dli' $C.Blue 130; $btnActLoad.Location=New-Object System.Drawing.Point(10,10)
$pnlActB.Controls.Add($btnActLoad)
$rtbAct=New-RTB; $rtbAct.Dock='Fill'; $rtbAct.Text='Click "Run slmgr /dli" to retrieve Windows license status.'
$stAct.Controls.AddRange(@($rtbAct,$pnlActB))
$subIIS.TabPages.AddRange(@($stIIS,$stAct))
$tabIIS.Controls.Add($subIIS)

# ═══════════════════════════════════════════════════════════════════════════
# TAB 23 — PERFORMANCE+
# ═══════════════════════════════════════════════════════════════════════════
$tabPerf=New-Object System.Windows.Forms.TabPage; $tabPerf.Text='  Performance+  '; $tabPerf.BackColor=$C.BgDark
$pnlPerfB=New-Object System.Windows.Forms.Panel; $pnlPerfB.Dock='Top'; $pnlPerfB.Height=48; $pnlPerfB.BackColor=$C.BgBar
$btnPerfRef =New-Btn 'Refresh All' $C.Blue 110;              $btnPerfRef.Location =New-Object System.Drawing.Point(10,10)
$chkPerfLive=New-Object System.Windows.Forms.CheckBox; $chkPerfLive.Text='Live (3s)'; $chkPerfLive.ForeColor=$C.Muted
$chkPerfLive.AutoSize=$true; $chkPerfLive.Location=New-Object System.Drawing.Point(128,14)
$pnlPerfB.Controls.AddRange(@($btnPerfRef,$chkPerfLive))
$splitPerf=New-Object System.Windows.Forms.SplitContainer; $splitPerf.Dock='Fill'
$splitPerf.Orientation='Vertical'; $splitPerf.SplitterDistance=300; $splitPerf.BackColor=$C.BgDark
$splitPerfR=New-Object System.Windows.Forms.SplitContainer; $splitPerfR.Dock='Fill'
$splitPerfR.Orientation='Horizontal'; $splitPerfR.SplitterDistance=320; $splitPerfR.BackColor=$C.BgDark
# Left: per-core CPU
$hCore=New-SecHdr 'Per-Core CPU'; $gCore=New-Grid; $gCore.Dock='Fill'; $gCore.AutoSizeColumnsMode='Fill'
$splitPerf.Panel1.Controls.AddRange(@($gCore,$hCore))
# Top-right: handle / GDI leaks
$hHnd=New-SecHdr 'Handle / GDI Leaks  (top 35 by handle count)'
$gHnd=New-Grid; $gHnd.Dock='Fill'
foreach($c in @('Name','PID','Handles','GDI','User','RAM(MB)','Path')){$gHnd.Columns.Add($c,$c)|Out-Null}
$gHnd.Columns['Name'].Width=140; $gHnd.Columns['PID'].Width=55; $gHnd.Columns['Handles'].Width=72
$gHnd.Columns['GDI'].Width=55; $gHnd.Columns['User'].Width=55; $gHnd.Columns['RAM(MB)'].Width=78; $gHnd.Columns['Path'].Width=380
$splitPerfR.Panel1.Controls.AddRange(@($gHnd,$hHnd))
# Bottom-right: network bandwidth
$hBW=New-SecHdr 'Network Bandwidth  (KB/s)'; $gBW=New-Grid; $gBW.Dock='Fill'; $gBW.AutoSizeColumnsMode='Fill'
$splitPerfR.Panel2.Controls.AddRange(@($gBW,$hBW))
$splitPerf.Panel2.Controls.Add($splitPerfR)
$tabPerf.Controls.AddRange(@($splitPerf,$pnlPerfB))

# ─── Force dark background on every TabPage (UseVisualStyleBackColor=true overrides BackColor by default) ──
foreach($tp in @(
    $tabH,$tabEv,$tabNet,$tabPT,$tabPerm,$tabSvc,$tabSec,
    $tabSI,$tabUpd,$tabCert,$tabTask,$tabAuto,$tabRel,$tabAD,$tabGPO,$tabISCSI,$tabSSL,
    $tabLP,$tabPS,$tabND,$tabIS,$tabIIS,$tabPerf,
    $stNTFS,$stShr,$stAcc,$stGrp,
    $stIIS,$stAct
)){
    $tp.UseVisualStyleBackColor=$false
    $tp.BackColor=$C.BgDark
}

# ─── Assemble tabs ────────────────────────────────────────────────────────────
$tabs.TabPages.AddRange(@($tabH,$tabEv,$tabNet,$tabPT,$tabPerm,$tabSvc,$tabSec,$tabSI,$tabUpd,$tabCert,$tabTask,$tabAuto,$tabRel,$tabAD,$tabGPO,$tabISCSI,$tabSSL,$tabLP,$tabPS,$tabND,$tabIS,$tabIIS,$tabPerf))
$pnlMain=New-Object System.Windows.Forms.Panel; $pnlMain.Dock='Fill'; $pnlMain.Controls.Add($tabs)
$form.Controls.AddRange(@($pnlMain,$pnlTitle,$strip))

# ═══════════════════════════════════════════════════════════════════════════
# LOGIC FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
$script:evtData  = @()
$script:svcData  = @()
$script:certData = @()
$script:taskData = @()
$script:relData  = @()
$script:formReady= $false
$script:webRS    = $null
$script:webPS    = $null
$script:webData  = [hashtable]::Synchronized(@{
    Running   = $false
    Port      = 8080
    Listener  = $null
    HTML      = ''
    Health    = '{}'
    Services  = '[]'
    Processes = '[]'
    Events    = '[]'
    Ports     = '[]'
    Certs     = '[]'
    Tasks     = '[]'
})

function Update-Health {
    if(-not $script:formReady){return}
    try {
    $sLbl.Text='Refreshing…'; $form.Refresh()
    $cpu=[math]::Round((Get-CPUUsage),1); Set-Card $cCPU "$cpu%" 'Processor load' (PctColor $cpu)
    $m=Get-MemInfo; Set-Card $cMEM "$($m.Pct)%" "$($m.U) / $($m.T) GB" (PctColor $m.Pct)
    $disks=Get-DiskInfo; $c=$disks|Where-Object DeviceID -eq 'C:'
    if($c){ Set-Card $cDSK "$($c.'Used%')%" "$($c.'Free(GB)') GB free / $($c.'Size(GB)') GB" (PctColor $c.'Used%') }
    $gpu=Get-GPUs|Select-Object -First 1
    if($gpu){
        $gn=if($gpu.Name -and $gpu.Name.Length -gt 22){$gpu.Name.Substring(0,22)+'…'}elseif($gpu.Name){$gpu.Name}else{'GPU'}
        $gr=if($gpu.AdapterRAM){"$([math]::Round($gpu.AdapterRAM/1GB,1)) GB"}else{'?'}
        Set-Card $cGPU 'OK' "$gn  |  $gr VRAM" $C.Ok
    } else { Set-Card $cGPU 'N/A' 'No GPU detected' $C.Muted }

    $dt=New-DT @('Name','PID','CPU(s)','RAM(MB)','Threads','Path')
    foreach($p in (Get-TopProcs)){
        $r=$dt.NewRow(); $r['Name']=$p.Name; $r['PID']=$p.Id; $r['CPU(s)']=$p.'CPU(s)'
        $r['RAM(MB)']=$p.'RAM(MB)'; $r['Threads']=$p.Threads; $r['Path']=$p.Path; $dt.Rows.Add($r)
    }
    $gProc.DataSource=$null; $gProc.Columns.Clear(); $gProc.DataSource=$dt
    if($gProc.Columns.Count -ge 6){
        $gProc.Columns['Name'].Width=130; $gProc.Columns['PID'].Width=60
        $gProc.Columns['CPU(s)'].Width=72; $gProc.Columns['RAM(MB)'].Width=78
        $gProc.Columns['Threads'].Width=65; $gProc.Columns['Path'].Width=540
    }

    $dt2=New-DT @('Drive','Size(GB)','Free(GB)','Used%')
    foreach($d in $disks){
        $r=$dt2.NewRow(); $r['Drive']=$d.DeviceID; $r['Size(GB)']=$d.'Size(GB)'
        $r['Free(GB)']=$d.'Free(GB)'; $r['Used%']="$($d.'Used%')%"; $dt2.Rows.Add($r)
    }
    $gDrv.DataSource=$null; $gDrv.Columns.Clear(); $gDrv.DataSource=$dt2

    $sb=[System.Text.StringBuilder]::new()
    $sb.AppendLine('═══ GPU ═══')|Out-Null
    foreach($g in (Get-GPUs)){
        $ram=if($g.AdapterRAM){"$([math]::Round($g.AdapterRAM/1GB,1)) GB"}else{'N/A'}
        $sb.AppendLine("  Name  : $($g.Name)")|Out-Null; $sb.AppendLine("  VRAM  : $ram")|Out-Null
        $sb.AppendLine("  Res   : $($g.VideoModeDescription)")|Out-Null; $sb.AppendLine('')|Out-Null
    }
    $sb.AppendLine('═══ Network Adapters ═══')|Out-Null
    foreach($n in (Get-Nets)){
        $sb.AppendLine("  Adapter : $($n.Description)")|Out-Null
        $sb.AppendLine("  IP(s)   : $($n.IPAddress -join ', ')")|Out-Null
        $sb.AppendLine("  Gateway : $($n.DefaultIPGateway -join ', ')")|Out-Null
        $sb.AppendLine("  MAC     : $($n.MACAddress)")|Out-Null
        $sb.AppendLine("  DHCP    : $($n.DHCPEnabled)")|Out-Null; $sb.AppendLine('')|Out-Null
    }
    $rtbInfo.Text=$sb.ToString()
    $lblRefAt.Text="Last refreshed: $(Get-Date -Format 'HH:mm:ss')"; $sLbl.Text='Ready'
    } catch { $sLbl.Text="Health error: $($_.Exception.Message)" }
}

function Load-Events {
    try {
    $sLbl.Text='Querying event log…'; $form.Refresh()
    $script:evtData=Get-WinEvents $cmbEvLog.SelectedItem $cmbEvLvl.SelectedItem ([int]$numEvHrs.Value) 500 $txtEvSrch.Text
    $dt=New-DT @('Time','ID','Level','Source','Message')
    foreach($e in $script:evtData){
        $r=$dt.NewRow(); $r['Time']=$e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); $r['ID']=$e.Id
        $r['Level']=$e.LevelDisplayName; $r['Source']=$e.ProviderName
        $r['Message']=($e.Message -split "`n")[0] -replace '\s+',' '; $dt.Rows.Add($r)
    }
    $gEv.DataSource=$null; $gEv.Columns.Clear(); $gEv.DataSource=$dt
    if($gEv.Columns.Count -ge 5){
        $gEv.Columns['Time'].Width=148; $gEv.Columns['ID'].Width=55
        $gEv.Columns['Level'].Width=90; $gEv.Columns['Source'].Width=210; $gEv.Columns['Message'].Width=560
    }
    foreach($row in $gEv.Rows){
        $row.DefaultCellStyle.ForeColor=switch($row.Cells['Level'].Value){
            'Critical'{$C.Err} 'Error'{[System.Drawing.Color]::FromArgb(255,110,110)} 'Warning'{$C.Warn} default{[System.Drawing.Color]::FromArgb(200,205,225)}
        }
    }
    $lblEvCnt.Text="  $($script:evtData.Count) event(s)  |  $($cmbEvLog.SelectedItem)  |  last $($numEvHrs.Value) hrs"; $sLbl.Text='Ready'
    } catch { $sLbl.Text="Event error: $($_.Exception.Message)" }
}

function Run-Ports($target,$tests) {
    foreach($t in $tests){
        $sLbl.Text="Testing $($t.N) on $target…"; $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $sw=[System.Diagnostics.Stopwatch]::StartNew()
        $status=if($t.Proto -eq 'TCP'){Test-TCP $target $t.P 3000}else{Test-UDP $target $t.P 2000}
        $sw.Stop(); $lat=if($status -eq 'Open'){$sw.ElapsedMilliseconds}else{'—'}
        $ri=$gPT.Rows.Add(); $row=$gPT.Rows[$ri]
        $row.Cells['Target'].Value=$target; $row.Cells['Group'].Value=$t.Group
        $row.Cells['Service'].Value=$t.N; $row.Cells['Port'].Value=$t.P
        $row.Cells['Protocol'].Value=$t.Proto; $row.Cells['Status'].Value=$status
        $row.Cells['Latency(ms)'].Value=$lat
        $row.DefaultCellStyle.ForeColor=switch($status){'Open'{$C.Ok}'Closed'{$C.Err}default{$C.Warn}}
        $gPT.FirstDisplayedScrollingRowIndex=$ri
        [System.Windows.Forms.Application]::DoEvents()
    }
    $sLbl.Text="Done — $($tests.Count) port(s) tested on $target"
}

function Load-Services {
    if(-not $script:formReady){return}
    $sLbl.Text='Loading services…'; $form.Refresh()
    try {
    $filter=if($cmbSvcSt.SelectedItem){''+$cmbSvcSt.SelectedItem}else{'All'}
    $srch=$txtSvcF.Text.Trim()
    $svcs=@(Get-Service -EA SilentlyContinue)
    if($filter -ne 'All'){$svcs=@($svcs|Where-Object{$_ -ne $null -and $_.Status -ne $null -and $_.Status.ToString() -eq $filter})}
    if($srch){$svcs=@($svcs|Where-Object{$_ -ne $null -and ($_.Name -like "*$srch*" -or $_.DisplayName -like "*$srch*")})}
    $dt=New-DT @('Name','Display Name','Status','Start Type')
    foreach($s in @($svcs|Sort-Object DisplayName)){
        if($null -eq $s){continue}
        try{
            $r=$dt.NewRow()
            $r[0]=[string]$s.Name
            $r[1]=[string]$s.DisplayName
            $r[2]=$s.Status.ToString()
            $r[3]=try{$s.StartType.ToString()}catch{'?'}
            $dt.Rows.Add($r)
        }catch{continue}
    }
    $gSvc.DataSource=$null; $gSvc.Columns.Clear(); $gSvc.DataSource=$dt
    if($gSvc.Columns.Count -ge 4){
        if($gSvc.Columns['Name'])         {$gSvc.Columns['Name'].Width=185}
        if($gSvc.Columns['Display Name']) {$gSvc.Columns['Display Name'].Width=310}
        if($gSvc.Columns['Status'])       {$gSvc.Columns['Status'].Width=90}
        if($gSvc.Columns['Start Type'])   {$gSvc.Columns['Start Type'].Width=120}
    }
    foreach($row in $gSvc.Rows){
        if($null -eq $row){continue}
        $sv=$row.Cells['Status']
        if($null -eq $sv -or $null -eq $sv.Value -or $sv.Value -is [System.DBNull]){continue}
        if($sv.Value.ToString() -eq 'Running'){ $row.DefaultCellStyle.ForeColor=$C.Ok }
        else                                  { $row.DefaultCellStyle.ForeColor=$C.Muted }
    }
    $lblSvcCnt.Text="  $($dt.Rows.Count) services shown"; $sLbl.Text='Ready'
    } catch { $sLbl.Text="Filter error L$($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" }
}

function Load-Security {
    $sLbl.Text='Loading security info…'; $form.Refresh()
    $sb=[System.Text.StringBuilder]::new()

    # Firewall
    $sb.AppendLine('═══ Windows Firewall ═══')|Out-Null
    $fw=Get-FWStatus
    if($fw){
        foreach($p in $fw){
            $icon=if($p.Enabled){'[ON] '}else{'[OFF]'}
            $sb.AppendLine("  $icon $($p.Name.PadRight(10))  Inbound: $($p.DefaultInboundAction)   Outbound: $($p.DefaultOutboundAction)")|Out-Null
        }
    }else{$sb.AppendLine('  (requires elevation)')|Out-Null}

    # Defender
    $sb.AppendLine(''); $sb.AppendLine('═══ Windows Defender / AV ═══')|Out-Null
    $def=Get-DefStatus
    if($def){
        $sb.AppendLine("  Real-Time Protection : $($def.RealTimeProtectionEnabled)")|Out-Null
        $sb.AppendLine("  Anti-Spyware         : $($def.AntiSpywareEnabled)")|Out-Null
        $sb.AppendLine("  AV Signatures        : $($def.AntivirusSignatureVersion)")|Out-Null
        $sb.AppendLine("  Running Mode         : $($def.AMRunningMode)")|Out-Null
        $sb.AppendLine("  Last Quick Scan      : $($def.QuickScanEndTime)")|Out-Null
    }else{$sb.AppendLine('  (unable to query Defender)')|Out-Null}

    # Token / UAC
    $sb.AppendLine(''); $sb.AppendLine('═══ UAC / Token ═══')|Out-Null
    $wid=[System.Security.Principal.WindowsIdentity]::GetCurrent()
    $wp =New-Object System.Security.Principal.WindowsPrincipal($wid)
    $isAdmin=$wp.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    $sb.AppendLine("  User             : $($wid.Name)")|Out-Null
    $sb.AppendLine("  Running as Admin : $isAdmin")|Out-Null
    $sb.AppendLine("  Auth Type        : $($wid.AuthenticationType)")|Out-Null
    $sb.AppendLine("  Impersonation    : $($wid.ImpersonationLevel)")|Out-Null

    # Pending reboot
    $sb.AppendLine(''); $sb.AppendLine('═══ Pending Reboot ═══')|Out-Null
    $pr=$false
    if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){$pr=$true}
    if(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue){$pr=$true}
    if(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){$pr=$true}
    $sb.AppendLine("  Pending Reboot : $pr")|Out-Null

    # Installed hotfixes (last 10)
    $sb.AppendLine(''); $sb.AppendLine('═══ Recent Hotfixes (last 10) ═══')|Out-Null
    try {
        Get-HotFix -EA Stop | Sort-Object InstalledOn -Descending | Select-Object -First 10 |
            ForEach-Object { $sb.AppendLine("  $($_.HotFixID.PadRight(12)) $($_.InstalledOn)  $($_.Description)")|Out-Null }
    } catch { $sb.AppendLine('  (unable to query hotfixes)')|Out-Null }

    $rtbSec.Text=$sb.ToString()

    # Local users grid
    $dt=New-DT @('Name','Enabled','Last Logon','Pwd Required','Description')
    foreach($u in (Get-LocalUsrs)){
        $r=$dt.NewRow(); $r['Name']=$u.Name; $r['Enabled']=$u.Enabled
        $r['Last Logon']=$u.LastLogon; $r['Pwd Required']=$u.PasswordRequired
        $r['Description']=$u.Description; $dt.Rows.Add($r)
    }
    $gUsers.DataSource=$null; $gUsers.Columns.Clear(); $gUsers.DataSource=$dt

    # Local groups grid
    $dt2=New-DT @('Group','Description')
    foreach($g in (Get-LocalGrps)){$r=$dt2.NewRow(); $r['Group']=$g.Name; $r['Description']=$g.Description; $dt2.Rows.Add($r)}
    $gGrps.DataSource=$null; $gGrps.Columns.Clear(); $gGrps.DataSource=$dt2

    $sLbl.Text='Ready'
}

function Load-SysInfo {
    $sLbl.Text='Loading system info…'; $form.Refresh()
    $i=Get-SysInfo
    $sb=[System.Text.StringBuilder]::new()
    $sb.AppendLine('═══ Operating System ═══')|Out-Null
    $sb.AppendLine("  Caption      : $($i.OSCaption)")|Out-Null
    $sb.AppendLine("  Build        : $($i.OSBuild)  ($($i.OSArch))")|Out-Null
    $sb.AppendLine("  Install Date : $($i.InstallDate)")|Out-Null
    $sb.AppendLine("  Last Boot    : $($i.LastBoot)")|Out-Null
    $sb.AppendLine("  Uptime       : $($i.Uptime)")|Out-Null
    $sb.AppendLine('')|Out-Null; $sb.AppendLine('═══ Hardware ═══')|Out-Null
    $sb.AppendLine("  Computer     : $($i.Computer)")|Out-Null
    $sb.AppendLine("  Manufacturer : $($i.Mfr)")|Out-Null
    $sb.AppendLine("  Model        : $($i.Model)")|Out-Null
    $sb.AppendLine("  RAM          : $($i.RAM)")|Out-Null
    $sb.AppendLine("  BIOS         : $($i.BIOSVer)")|Out-Null
    $sb.AppendLine("  BIOS Date    : $($i.BIOSDate)")|Out-Null
    $sb.AppendLine("  Hypervisor   : $($i.VM)")|Out-Null
    $sb.AppendLine('')|Out-Null; $sb.AppendLine('═══ Network / Domain ═══')|Out-Null
    $sb.AppendLine("  Domain       : $($i.Domain)")|Out-Null
    $sb.AppendLine('')|Out-Null; $sb.AppendLine('═══ Software ═══')|Out-Null
    $sb.AppendLine("  PowerShell   : $($i.PSVer)")|Out-Null
    $sb.AppendLine("  .NET Versions: $($i.DotNet)")|Out-Null
    $sb.AppendLine("  Page File    : $($i.PageFile)")|Out-Null
    $rtbSI.Text=$sb.ToString(); $sLbl.Text='Ready'
}

function Load-UpdateHistory {
    $sLbl.Text='Loading update history…'; $form.Refresh()
    $rows=Get-UpdateHistory
    $dt=New-DT @('Date','KB','Operation','Result','Title')
    foreach($r in $rows){
        $row=$dt.NewRow(); $row['Date']=$r.Date.ToString('yyyy-MM-dd HH:mm')
        $row['KB']=$r.KB; $row['Operation']=$r.Operation
        $row['Result']=$r.ResultCode; $row['Title']=$r.Title; $dt.Rows.Add($row)
    }
    $gUpd.DataSource=$null; $gUpd.Columns.Clear(); $gUpd.DataSource=$dt
    if($gUpd.Columns.Count -ge 5){
        $gUpd.Columns['Date'].Width=145; $gUpd.Columns['KB'].Width=85
        $gUpd.Columns['Operation'].Width=90; $gUpd.Columns['Result'].Width=90
        $gUpd.Columns['Title'].Width=700
    }
    foreach($row in $gUpd.Rows){
        if($row.Cells['Result'].Value -eq 'Error'){$row.DefaultCellStyle.ForeColor=$C.Err}
        elseif($row.Cells['Result'].Value -eq 'OK'){$row.DefaultCellStyle.ForeColor=$C.Ok}
    }
    $lblUpdCnt.Text="  $($rows.Count) update(s) in history"; $sLbl.Text='Ready'
}

function Load-PendingUpdates {
    $sLbl.Text='Checking pending updates (this can take ~30s)…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $rows=Get-PendingUpdates
    $dt=New-DT @('KB','Severity','Size','Published','Title')
    foreach($r in $rows){
        $row=$dt.NewRow(); $row['KB']=$r.KB; $row['Severity']=$r.Severity
        $row['Size']=$r.Size; $row['Published']=$r.Published.ToString('yyyy-MM-dd')
        $row['Title']=$r.Title; $dt.Rows.Add($row)
    }
    $gUpd.DataSource=$null; $gUpd.Columns.Clear(); $gUpd.DataSource=$dt
    if($gUpd.Columns.Count -ge 5){
        $gUpd.Columns['KB'].Width=90; $gUpd.Columns['Severity'].Width=100
        $gUpd.Columns['Size'].Width=80; $gUpd.Columns['Published'].Width=100
        $gUpd.Columns['Title'].Width=700
    }
    foreach($row in $gUpd.Rows){
        if($row.Cells['Severity'].Value -eq 'Critical'){$row.DefaultCellStyle.ForeColor=$C.Err}
        elseif($row.Cells['Severity'].Value -eq 'Important'){$row.DefaultCellStyle.ForeColor=$C.Warn}
    }
    $lblUpdCnt.Text="  $($rows.Count) pending update(s)"; $sLbl.Text='Ready'
}

function Load-Certs {
    $sLbl.Text='Scanning certificate stores…'; $form.Refresh()
    $script:certData=Get-CertStore
    $filter=$cmbCertFilter.SelectedItem
    $rows=if($filter -eq 'All'){$script:certData}else{$script:certData|Where-Object Status -eq $filter}
    $gCert.Rows.Clear()
    foreach($c in $rows){
        $ri=$gCert.Rows.Add()
        $row=$gCert.Rows[$ri]
        $row.Cells['Store'].Value=$c.Store; $row.Cells['Subject'].Value=$c.Subject
        $row.Cells['Issuer'].Value=$c.Issuer; $row.Cells['Expires'].Value=$c.Expires.ToString('yyyy-MM-dd HH:mm')
        $row.Cells['DaysLeft'].Value=$c.DaysLeft; $row.Cells['Status'].Value=$c.Status
        $row.Cells['Thumbprint'].Value=$c.Thumbprint
        $row.DefaultCellStyle.ForeColor=switch($c.Status){'EXPIRED'{$C.Err}'EXPIRING'{$C.Warn}default{$C.Ok}}
    }
    $lblCertCnt.Text="  $($rows.Count) certificate(s) shown  |  $(($script:certData|Where-Object Status -eq 'EXPIRED').Count) expired  |  $(($script:certData|Where-Object Status -eq 'EXPIRING').Count) expiring soon"
    $sLbl.Text='Ready'
}

function Load-Tasks {
    $sLbl.Text='Loading scheduled tasks…'; $form.Refresh()
    $script:taskData=Get-TasksInfo
    $filter=$cmbTaskFilter.SelectedItem
    $rows=switch($filter){
        'Failed'   {$script:taskData|Where-Object {-not $_.OK}}
        'Running'  {$script:taskData|Where-Object {$_.State -eq 'Running'}}
        'Disabled' {$script:taskData|Where-Object {$_.State -eq 'Disabled'}}
        default    {$script:taskData}
    }
    $gTask.Rows.Clear()
    foreach($t in $rows){
        $ri=$gTask.Rows.Add(); $row=$gTask.Rows[$ri]
        $row.Cells['Name'].Value=$t.Name; $row.Cells['Path'].Value=$t.Path
        $row.Cells['State'].Value=$t.State
        $row.Cells['Last Run'].Value=if($t.LastRun -is [datetime]){$t.LastRun.ToString('yyyy-MM-dd HH:mm')}else{$t.LastRun}
        $row.Cells['Next Run'].Value=if($t.NextRun -is [datetime]){$t.NextRun.ToString('yyyy-MM-dd HH:mm')}else{$t.NextRun}
        $row.Cells['Last Result'].Value=$t.LastResult
        if(-not $t.OK){$row.DefaultCellStyle.ForeColor=$C.Err}
        elseif($t.State -eq 'Disabled'){$row.DefaultCellStyle.ForeColor=$C.Muted}
        else{$row.DefaultCellStyle.ForeColor=$C.Ok}
    }
    $lblTaskCnt.Text="  $($rows.Count) task(s) shown  |  $(($script:taskData|Where-Object{-not $_.OK}).Count) failures"
    $sLbl.Text='Ready'
}

function Load-Autoruns {
    $sLbl.Text='Scanning startup entries…'; $form.Refresh()
    $items=Get-AutorunInfo
    $dt=New-DT @('Source','Name','Command')
    foreach($i in $items){
        $r=$dt.NewRow(); $r['Source']=$i.Source; $r['Name']=$i.Name; $r['Command']=$i.Command; $dt.Rows.Add($r)
    }
    $gAuto.DataSource=$null; $gAuto.Columns.Clear(); $gAuto.DataSource=$dt
    if($gAuto.Columns.Count -ge 3){
        $gAuto.Columns['Source'].Width=140; $gAuto.Columns['Name'].Width=210; $gAuto.Columns['Command'].Width=700
    }
    $lblAutoCnt.Text="  $($items.Count) startup item(s)"; $sLbl.Text='Ready'
}

function Load-Reliability {
    $sLbl.Text='Loading reliability events…'; $form.Refresh()
    $script:relData=Get-ReliabilityInfo
    $gRel.Rows.Clear()
    foreach($e in $script:relData){
        $ri=$gRel.Rows.Add(); $row=$gRel.Rows[$ri]
        $row.Cells['Time'].Value=$e.Time.ToString('yyyy-MM-dd HH:mm'); $row.Cells['Type'].Value=$e.Type
        $row.Cells['Source'].Value=$e.Source; $row.Cells['Message'].Value=$e.Message
        $row.DefaultCellStyle.ForeColor=switch -Regex ($e.Type){
            'Crash|Fail|Error' {$C.Err} 'Recover|Install' {$C.Warn} default {[System.Drawing.Color]::FromArgb(200,205,225)}
        }
    }
    $sLbl.Text="Ready — $($script:relData.Count) event(s)"
}

function Load-SSL($host,[int]$port) {
    $sLbl.Text="Connecting to $host`:$port…"; $form.Refresh()
    $r=Test-SSLEndpoint $host $port
    $sb=[System.Text.StringBuilder]::new()
    if($r.OK){
        $sb.AppendLine("═══ Certificate  $host`:$port ═══")|Out-Null
        $sb.AppendLine("  Subject    : $($r.Subject)")|Out-Null
        $sb.AppendLine("  Issuer     : $($r.Issuer)")|Out-Null
        $sb.AppendLine("  Thumbprint : $($r.Thumbprint)")|Out-Null
        $sb.AppendLine("  Valid From : $($r.NotBefore)")|Out-Null
        $sb.AppendLine("  Expires    : $($r.NotAfter)")|Out-Null
        $status=if($r.DaysLeft -lt 0){'EXPIRED'}elseif($r.DaysLeft -le 30){"EXPIRING in $($r.DaysLeft) days"}else{"OK — $($r.DaysLeft) days remaining"}
        $sb.AppendLine("  Status     : $status")|Out-Null
        $sb.AppendLine("  Protocol   : $($r.Protocol)")|Out-Null
        $sb.AppendLine("  Chain      : $($r.Chain)")|Out-Null
        if($r.SANs){$sb.AppendLine("  SANs       : $($r.SANs)")|Out-Null}
    } else {
        $sb.AppendLine("FAILED: $($r.Err)")|Out-Null
    }
    $rtbSSL.Text=$sb.ToString(); $sLbl.Text='Ready'
}

function Load-ListeningPorts {
    $sLbl.Text='Scanning listening ports…'; $form.Refresh()
    $proto = if($cmbLPProto.SelectedItem){''+$cmbLPProto.SelectedItem}else{'All'}
    $srch  = $txtLPSrch.Text.Trim()
    $data  = @(Get-ListeningPorts)
    if($proto -ne 'All'){ $data = @($data | Where-Object {$_.Proto -eq $proto}) }
    if($srch){
        $data = @($data | Where-Object {
            $_.Process -like "*$srch*" -or [string]$_.Port -eq $srch -or $_.Path -like "*$srch*"
        })
    }
    $gLP.Rows.Clear()
    foreach($p in $data){
        $ri=$gLP.Rows.Add(); $row=$gLP.Rows[$ri]
        $row.Cells['Proto'].Value     = $p.Proto
        $row.Cells['Local Addr'].Value= $p.LocalAddr
        $row.Cells['Port'].Value      = $p.Port
        $row.Cells['Remote Addr'].Value=$p.RemoteAddr
        $row.Cells['Rem Port'].Value  = $p.RemotePort
        $row.Cells['State'].Value     = $p.State
        $row.Cells['PID'].Value       = $p.PID
        $row.Cells['Process'].Value   = $p.Process
        $row.Cells['Path'].Value      = $p.Path
        $row.DefaultCellStyle.ForeColor = if($p.Proto -eq 'TCP'){$C.Accent}else{$C.Warn}
    }
    $lblLPCnt.Text="  $($data.Count) port(s) shown"; $sLbl.Text='Ready'
}

$script:psSweeping = $false

function Start-PingSweep {
    $range = $txtPSRange.Text.Trim()
    if(-not $range){ [System.Windows.Forms.MessageBox]::Show('Enter an IP range.','Ping Sweep'); return }
    $to  = [int]$numPSTo.Value
    $ips = @(Expand-IPRange $range)
    if($ips.Count -gt 1024){
        if([System.Windows.Forms.MessageBox]::Show("$($ips.Count) hosts to ping — this may take a while. Continue?","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo) -ne 'Yes'){return}
    }
    $gPS.Rows.Clear(); $lblPSCnt.Text='  Sweeping…'
    $script:psSweeping = $true
    $btnPSSweep.Enabled = $false; $btnPSStop.Enabled = $true
    $ping = New-Object System.Net.NetworkInformation.Ping
    $up=0; $total=0
    foreach($ip in $ips){
        if(-not $script:psSweeping){break}
        $total++
        $ri=$gPS.Rows.Add(); $row=$gPS.Rows[$ri]
        $row.Cells['IP'].Value=''+$ip; $row.Cells['Status'].Value='Pinging…'
        $gPS.FirstDisplayedScrollingRowIndex=$ri
        [System.Windows.Forms.Application]::DoEvents()
        try{
            $reply=$ping.Send($ip,$to)
            if($reply.Status -eq 'Success'){
                $up++
                $row.Cells['Status'].Value='Up'; $row.Cells['RTT(ms)'].Value=$reply.RoundtripTime
                $row.DefaultCellStyle.ForeColor=$C.Ok
                try{ $row.Cells['Hostname'].Value=[System.Net.Dns]::GetHostEntry($ip).HostName }catch{ $row.Cells['Hostname'].Value='—' }
            } else {
                $row.Cells['Status'].Value='Down'; $row.Cells['RTT(ms)'].Value='—'
                $row.DefaultCellStyle.ForeColor=$C.Muted; $row.Cells['Hostname'].Value='—'
            }
        } catch {
            $row.Cells['Status'].Value='Error'; $row.Cells['RTT(ms)'].Value='—'
            $row.DefaultCellStyle.ForeColor=$C.Err; $row.Cells['Hostname'].Value='—'
        }
        $lblPSCnt.Text="  $total / $($ips.Count) pinged  |  $up up"
        [System.Windows.Forms.Application]::DoEvents()
    }
    $ping.Dispose()
    $script:psSweeping=$false
    $btnPSSweep.Enabled=$true; $btnPSStop.Enabled=$false
    $lblPSCnt.Text="  Done — $total pinged  |  $up up  |  $($total-$up) down"
    $sLbl.Text='Ping sweep complete'
}

function Load-NetDetails {
    $sLbl.Text='Loading ARP cache + DHCP info…'; $form.Refresh()
    # ARP cache
    $arp=@(Get-ARPCache)
    $dt=New-DT @('Interface','IP Address','MAC Address','State')
    foreach($a in $arp){
        $r=$dt.NewRow(); $r['Interface']=$a.InterfaceAlias; $r['IP Address']=$a.IPAddress
        $r['MAC Address']=$a.LinkLayerAddress; $r['State']=$a.State; $dt.Rows.Add($r)
    }
    $gARP.DataSource=$null; $gARP.Columns.Clear(); $gARP.DataSource=$dt
    # DHCP leases
    $dhcp=@(Get-DHCPInfo)
    $dt2=New-DT @('Adapter','IP','DHCP Server','Lease Obtained','Lease Expires')
    foreach($d in $dhcp){
        $r=$dt2.NewRow(); $r['Adapter']=$d.Description; $r['IP']=$d.IP
        $r['DHCP Server']=$d.'DHCP Server'
        $r['Lease Obtained']=if($d.'Lease Obtained'){"$($d.'Lease Obtained')"}else{'—'}
        $r['Lease Expires']=if($d.'Lease Expires'){"$($d.'Lease Expires')"}else{'—'}
        $dt2.Rows.Add($r)
    }
    $gDHCP.DataSource=$null; $gDHCP.Columns.Clear(); $gDHCP.DataSource=$dt2
    $sLbl.Text="ARP: $($arp.Count) entries  |  DHCP: $($dhcp.Count) lease(s)"
}

function Load-InstalledSoftware([string]$filter='') {
    $sLbl.Text='Scanning installed software…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $data=@(Get-InstalledSoftware $filter)
    $dt=New-DT @('Name','Publisher','Version','Installed','Size(MB)')
    foreach($s in $data){
        $r=$dt.NewRow(); $r['Name']=$s.DisplayName; $r['Publisher']=''+$s.Publisher
        $r['Version']=''+$s.DisplayVersion; $r['Installed']=''+$s.Installed; $r['Size(MB)']=''+$s.'Size(MB)'
        $dt.Rows.Add($r)
    }
    $gIS.DataSource=$null; $gIS.Columns.Clear(); $gIS.DataSource=$dt
    if($gIS.Columns.Count -ge 5){
        $gIS.Columns['Name'].Width=310; $gIS.Columns['Publisher'].Width=215
        $gIS.Columns['Version'].Width=105; $gIS.Columns['Installed'].Width=90; $gIS.Columns['Size(MB)'].Width=80
    }
    $lblISCnt.Text="  $($data.Count) application(s) shown"; $sLbl.Text='Ready'
}

function Load-IISHealth {
    $sLbl.Text='Loading IIS health…'; $form.Refresh()
    $r=Get-IISHealth
    if(-not $r.Available){
        $gSites.Rows.Clear(); $gPools.Rows.Clear()
        $sLbl.Text='IIS not available — WebAdministration module not found or IIS not installed'
        return
    }
    $dt=New-DT @('Name','State','Path','Bindings')
    foreach($s in $r.Sites){
        $row=$dt.NewRow(); $row['Name']=$s.Name; $row['State']=''+$s.State
        $row['Path']=''+$s.PhysicalPath; $row['Bindings']=''+$s.Bindings; $dt.Rows.Add($row)
    }
    $gSites.DataSource=$null; $gSites.Columns.Clear(); $gSites.DataSource=$dt
    $dt2=New-DT @('Name','State','Runtime','Pipeline','Identity')
    foreach($p in $r.Pools){
        $row=$dt2.NewRow(); $row['Name']=$p.Name; $row['State']=''+$p.State
        $row['Runtime']=''+$p.ManagedRuntimeVersion; $row['Pipeline']=''+$p.Pipeline
        $row['Identity']=''+$p.Identity; $dt2.Rows.Add($row)
    }
    $gPools.DataSource=$null; $gPools.Columns.Clear(); $gPools.DataSource=$dt2
    foreach($row in $gSites.Rows){
        if($null -eq $row -or $null -eq $row.Cells['State'] -or $row.Cells['State'].Value -is [System.DBNull]){continue}
        if($row.Cells['State'].Value.ToString() -eq 'Started'){ $row.DefaultCellStyle.ForeColor=$C.Ok }
        else{ $row.DefaultCellStyle.ForeColor=$C.Err }
    }
    foreach($row in $gPools.Rows){
        if($null -eq $row -or $null -eq $row.Cells['State'] -or $row.Cells['State'].Value -is [System.DBNull]){continue}
        if($row.Cells['State'].Value.ToString() -eq 'Started'){ $row.DefaultCellStyle.ForeColor=$C.Ok }
        else{ $row.DefaultCellStyle.ForeColor=$C.Err }
    }
    $sLbl.Text="IIS loaded — $(@($r.Sites).Count) site(s), $(@($r.Pools).Count) pool(s)"
}

function Load-PerfAll {
    $sLbl.Text='Loading performance data…'; $form.Refresh()
    # Per-core CPU
    $cores=@(Get-PerCoreCPU)
    $dt=New-DT @('Core','Usage %')
    foreach($c in $cores){ $r=$dt.NewRow(); $r['Core']=$c.Core; $r['Usage %']=$c.'Usage %'; $dt.Rows.Add($r) }
    $gCore.DataSource=$null; $gCore.Columns.Clear(); $gCore.DataSource=$dt
    foreach($row in $gCore.Rows){
        $v=0; [double]::TryParse($row.Cells['Usage %'].Value,[ref]$v)|Out-Null
        $row.DefaultCellStyle.ForeColor=PctColor $v
    }
    # Handle / GDI leaks
    $handles=@(Get-HandleLeaks)
    $gHnd.Rows.Clear()
    foreach($p in $handles){
        $ri=$gHnd.Rows.Add(); $row=$gHnd.Rows[$ri]
        $row.Cells['Name'].Value=$p.Name; $row.Cells['PID'].Value=$p.PID
        $row.Cells['Handles'].Value=$p.Handles; $row.Cells['GDI'].Value=$p.GDI
        $row.Cells['User'].Value=$p.User; $row.Cells['RAM(MB)'].Value=$p.'RAM(MB)'
        $row.Cells['Path'].Value=$p.Path
        if($p.Handles -gt 5000 -or $p.GDI -gt 1000){ $row.DefaultCellStyle.ForeColor=$C.Err }
        elseif($p.Handles -gt 2000 -or $p.GDI -gt 500){ $row.DefaultCellStyle.ForeColor=$C.Warn }
    }
    # Network bandwidth
    $bw=@(Get-NetBandwidth)
    $dt3=New-DT @('Adapter','Send KB/s','Recv KB/s')
    foreach($a in $bw){
        $r=$dt3.NewRow(); $r['Adapter']=$a.Name; $r['Send KB/s']=$a.SendKBs; $r['Recv KB/s']=$a.RecvKBs
        $dt3.Rows.Add($r)
    }
    $gBW.DataSource=$null; $gBW.Columns.Clear(); $gBW.DataSource=$dt3
    $sLbl.Text="Perf refreshed at $(Get-Date -Format 'HH:mm:ss')"
}

# ═══════════════════════════════════════════════════════════════════════════
# WEB DASHBOARD
# ═══════════════════════════════════════════════════════════════════════════

function Refresh-WebData {
    # Health
    try {
        $cpu=[math]::Round((Get-CPUUsage),1); $mem=Get-MemInfo
        $dsks=@(Get-DiskInfo)
        $os=Get-CimInstance Win32_OperatingSystem
        $up=(Get-Date)-$os.LastBootUpTime
        $script:webData['Health']=ConvertTo-Json -Compress -Depth 4 ([ordered]@{
            hostname=$env:COMPUTERNAME; username=$env:USERNAME
            cpu=$cpu; ramPct=$mem.Pct; ramUsed=$mem.U; ramTotal=$mem.T
            uptime="$([int]$up.TotalDays)d $($up.Hours)h $($up.Minutes)m"
            timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            disks=@($dsks|ForEach-Object{[ordered]@{drive=$_.DeviceID;size=$_.'Size(GB)';free=$_.'Free(GB)';used=$_.'Used%'}})
        })
    } catch {}
    # Processes
    try {
        $script:webData['Processes']=ConvertTo-Json -Compress -Depth 2 @(Get-TopProcs|ForEach-Object{
            [ordered]@{name=$_.Name;pid=$_.Id;cpu=$_.'CPU(s)';ram=$_.'RAM(MB)';threads=$_.Threads;path=$_.Path}
        })
    } catch {}
    # Services
    try {
        $script:webData['Services']=ConvertTo-Json -Compress -Depth 2 @(
            Get-Service -EA SilentlyContinue|Where-Object{$_}|Sort-Object DisplayName|ForEach-Object{
                [ordered]@{name=$_.Name;display=$_.DisplayName;status=$_.Status.ToString();start=try{$_.StartType.ToString()}catch{'?'}}
            }
        )
    } catch {}
    # Events (System + Application errors, last 24h)
    try {
        $evts=@(Get-WinEvents 'System' 'Error' 24 75 '')+@(Get-WinEvents 'Application' 'Error' 24 50 '')
        $script:webData['Events']=ConvertTo-Json -Compress -Depth 2 @(
            $evts|Sort-Object TimeCreated -Descending|Select-Object -First 150|ForEach-Object{
                [ordered]@{time=$_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss');id=$_.Id;level=$_.LevelDisplayName;source=$_.ProviderName;message=(($_.Message -split "`n")[0] -replace '\s+',' ')}
            }
        )
    } catch {}
    # Listening Ports
    try {
        $script:webData['Ports']=ConvertTo-Json -Compress -Depth 2 @(
            Get-ListeningPorts|Select-Object -First 300|ForEach-Object{
                [ordered]@{proto=$_.Proto;addr=$_.LocalAddr;port=$_.Port;state=$_.State;pid=$_.PID;process=$_.Process;path=$_.Path}
            }
        )
    } catch {}
    # Certificates
    try {
        $script:webData['Certs']=ConvertTo-Json -Compress -Depth 2 @(
            Get-CertStore|ForEach-Object{
                [ordered]@{store=$_.Store;subject=$_.Subject;issuer=$_.Issuer;expires=$_.Expires.ToString('yyyy-MM-dd');days=$_.DaysLeft;status=$_.Status}
            }
        )
    } catch {}
    # Failed tasks
    try {
        $script:webData['Tasks']=ConvertTo-Json -Compress -Depth 2 @(
            Get-TasksInfo|Where-Object{-not $_.OK}|Select-Object -First 100|ForEach-Object{
                [ordered]@{name=$_.Name;path=$_.Path;state=$_.State;lastrun="$($_.LastRun)";lastresult=$_.LastResult}
            }
        )
    } catch {}
}

function Get-DashboardHtml {
@'
<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SRE Agent Dashboard</title>
<style>
:root{--bg:rgb(15,15,26);--mid:rgb(22,22,38);--card:rgb(30,30,52);--bar:rgb(25,25,42);--acc:rgb(0,200,255);--ok:rgb(80,220,120);--warn:rgb(255,190,50);--err:rgb(255,80,80);--muted:rgb(130,130,160);--grid:rgb(45,45,68)}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:#fff;font-family:'Segoe UI',Tahoma,sans-serif;font-size:13px}
a{color:var(--acc);text-decoration:none}
header{background:var(--card);padding:0 24px;height:52px;display:flex;align-items:center;justify-content:space-between;border-bottom:2px solid var(--acc);position:sticky;top:0;z-index:10}
header h1{color:var(--acc);font-size:16px;font-weight:700}
header .meta{color:var(--muted);font-size:12px;text-align:right;line-height:1.7}
nav{background:var(--bar);padding:0 16px;display:flex;border-bottom:1px solid var(--grid);position:sticky;top:52px;z-index:9}
nav button{background:none;border:none;border-bottom:2px solid transparent;color:var(--muted);padding:10px 18px;cursor:pointer;font-size:12px;font-family:inherit;transition:color .15s}
nav button:hover{color:#fff}
nav button.active{color:var(--acc);border-bottom-color:var(--acc)}
#cards{display:flex;flex-wrap:wrap;gap:12px;padding:16px 24px;background:var(--bg)}
.card{background:var(--card);border-radius:6px;padding:14px 18px;min-width:160px;flex:1}
.card .cl{color:var(--muted);font-size:11px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px}
.card .cv{font-size:26px;font-weight:700;margin-bottom:4px}
.card .cs{color:var(--muted);font-size:11px}
.pbar{height:5px;background:rgba(255,255,255,.1);border-radius:3px;overflow:hidden;margin-top:6px}
.pbar .fill{height:100%;border-radius:3px}
#content{padding:0 24px 70px}
.section{display:none}.section.active{display:block}
.toolbar{display:flex;align-items:center;gap:8px;padding:12px 0 8px;flex-wrap:wrap}
.toolbar input{background:rgb(38,38,60);border:1px solid var(--grid);color:#fff;padding:5px 12px;border-radius:4px;font-size:12px;width:250px;font-family:inherit}
.toolbar input:focus{outline:none;border-color:var(--acc)}
.fbtn{background:rgb(55,55,90);border:none;color:var(--muted);padding:4px 12px;border-radius:3px;cursor:pointer;font-size:11px;font-family:inherit}
.fbtn:hover,.fbtn.on{background:rgb(0,120,180);color:#fff}
.count{color:var(--muted);font-size:11px;margin-left:auto}
.sec-hdr{background:var(--bar);color:var(--acc);padding:8px 12px;font-size:12px;font-weight:600;border-left:3px solid var(--acc);margin:12px 0 2px}
.tbl-wrap{overflow-x:auto;max-height:calc(100vh - 270px);overflow-y:auto;background:var(--mid);border-radius:0 0 4px 4px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:var(--card);color:var(--acc);text-align:left;padding:8px 10px;font-weight:600;white-space:nowrap;position:sticky;top:0;z-index:1}
td{padding:6px 10px;border-bottom:1px solid var(--grid);white-space:nowrap;max-width:500px;overflow:hidden;text-overflow:ellipsis}
tr:hover td{background:rgb(27,27,44)}
.ok{color:var(--ok)}.warn{color:var(--warn)}.err{color:var(--err)}.muted{color:var(--muted)}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600}
.badge.ok{background:rgba(80,220,120,.15);color:var(--ok)}
.badge.err{background:rgba(255,80,80,.15);color:var(--err)}
.badge.warn{background:rgba(255,190,50,.15);color:var(--warn)}
.badge.muted{background:rgba(130,130,160,.15);color:var(--muted)}
.api-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px;padding:12px 0}
.api-card{background:var(--card);border-radius:5px;padding:12px 14px}
.api-card .method{color:var(--ok);font-size:11px;font-weight:700;font-family:monospace}
.api-card a{font-family:monospace;font-size:12px}
.api-card .desc{color:var(--muted);font-size:11px;margin-top:4px}
footer{position:fixed;bottom:0;left:0;right:0;background:var(--bar);border-top:1px solid var(--grid);padding:7px 24px;display:flex;align-items:center;justify-content:space-between;font-size:11px;color:var(--muted);z-index:10}
footer .fr{display:flex;align-items:center;gap:14px}
.ref-btn{background:rgb(0,120,180);border:none;color:#fff;padding:4px 14px;border-radius:3px;cursor:pointer;font-size:11px;font-family:inherit}
.ref-btn:hover{background:rgb(0,150,210)}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:5px;background:var(--ok)}
</style></head>
<body>
<header>
  <h1>&#9881; SRE Agent &nbsp;|&nbsp; Windows Diagnostics</h1>
  <div class="meta" id="hdr-meta">Loading&hellip;</div>
</header>
<nav>
  <button class="active" onclick="showTab('health')">System Health</button>
  <button onclick="showTab('processes')">Processes</button>
  <button onclick="showTab('services')">Services</button>
  <button onclick="showTab('events')">Events</button>
  <button onclick="showTab('ports')">Listening Ports</button>
  <button onclick="showTab('certs')">Certificates</button>
  <button onclick="showTab('tasks')">Failed Tasks</button>
  <button onclick="showTab('api')">API Endpoints</button>
</nav>
<div id="cards"></div>
<div id="content">
  <div id="tab-health" class="section active">
    <div id="disk-detail"></div>
  </div>
  <div id="tab-processes" class="section">
    <div class="toolbar">
      <input id="s-proc" placeholder="Filter name or path&hellip;" oninput="ft('tbl-proc',this.value)">
      <span class="count" id="c-proc"></span>
    </div>
    <div class="tbl-wrap"><table id="tbl-proc"><thead><tr><th>Name</th><th>PID</th><th>CPU(s)</th><th>RAM(MB)</th><th>Threads</th><th>Path</th></tr></thead><tbody></tbody></table></div>
  </div>
  <div id="tab-services" class="section">
    <div class="toolbar">
      <input id="s-svc" placeholder="Filter name&hellip;" oninput="svcSearch()">
      <button class="fbtn on" id="fb-all" onclick="svcMode('all')">All</button>
      <button class="fbtn" id="fb-run" onclick="svcMode('running')">Running</button>
      <button class="fbtn" id="fb-stp" onclick="svcMode('stopped')">Stopped</button>
      <span class="count" id="c-svc"></span>
    </div>
    <div class="tbl-wrap"><table id="tbl-svc"><thead><tr><th>Service Name</th><th>Display Name</th><th>Status</th><th>Start Type</th></tr></thead><tbody></tbody></table></div>
  </div>
  <div id="tab-events" class="section">
    <div class="toolbar">
      <input id="s-evt" placeholder="Filter source or message&hellip;" oninput="ft('tbl-evt',this.value)">
      <span class="count" id="c-evt"></span>
    </div>
    <div class="tbl-wrap"><table id="tbl-evt"><thead><tr><th>Time</th><th>ID</th><th>Level</th><th>Source</th><th>Message</th></tr></thead><tbody></tbody></table></div>
  </div>
  <div id="tab-ports" class="section">
    <div class="toolbar">
      <input id="s-port" placeholder="Filter process, port or address&hellip;" oninput="ft('tbl-port',this.value)">
      <span class="count" id="c-port"></span>
    </div>
    <div class="tbl-wrap"><table id="tbl-port"><thead><tr><th>Proto</th><th>Local Addr</th><th>Port</th><th>State</th><th>PID</th><th>Process</th><th>Path</th></tr></thead><tbody></tbody></table></div>
  </div>
  <div id="tab-certs" class="section">
    <div class="toolbar">
      <input id="s-cert" placeholder="Filter subject or store&hellip;" oninput="ft('tbl-cert',this.value)">
      <button class="fbtn on" id="cb-all" onclick="certMode('all')">All</button>
      <button class="fbtn" id="cb-exp" onclick="certMode('EXPIRED')">Expired</button>
      <button class="fbtn" id="cb-xp"  onclick="certMode('EXPIRING')">Expiring</button>
      <span class="count" id="c-cert"></span>
    </div>
    <div class="tbl-wrap"><table id="tbl-cert"><thead><tr><th>Store</th><th>Subject</th><th>Issuer</th><th>Expires</th><th>Days Left</th><th>Status</th></tr></thead><tbody></tbody></table></div>
  </div>
  <div id="tab-tasks" class="section">
    <div class="sec-hdr">Failed / Errored Scheduled Tasks</div>
    <div class="tbl-wrap"><table id="tbl-task"><thead><tr><th>Task Name</th><th>Path</th><th>State</th><th>Last Run</th><th>Last Result</th></tr></thead><tbody></tbody></table></div>
  </div>
  <div id="tab-api" class="section">
    <div class="sec-hdr">REST API Endpoints &mdash; all return JSON</div>
    <div class="api-grid" id="api-list"></div>
    <div class="sec-hdr" style="margin-top:18px">Example: fetch with PowerShell</div>
    <pre style="background:var(--card);padding:14px;border-radius:4px;font-size:12px;margin-top:2px;color:var(--ok);overflow-x:auto">Invoke-RestMethod http://HOST:PORT/api/health | ConvertTo-Json
Invoke-RestMethod http://HOST:PORT/api/services | Where-Object status -eq 'Stopped'</pre>
  </div>
</div>
<footer>
  <div><span class="dot"></span><span id="srv-lbl">SRE Agent Live</span></div>
  <div class="fr">
    <span id="last-ref">—</span>
    <label style="display:flex;align-items:center;gap:5px;cursor:pointer">
      <input type="checkbox" id="auto-chk" checked onchange="toggleAuto(this.checked)"> Auto&nbsp;30s
    </label>
    <button class="ref-btn" onclick="refreshAll()">&#8635; Refresh</button>
  </div>
</footer>
<script>
var svcAll=[],certAll=[],svcF='all',certF='all',autoT=null,curTab='health';
function e(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function pclr(p){return p>85?'var(--err)':p>65?'var(--warn)':'var(--ok)'}
function badge(t,c){return'<span class="badge '+c+'">'+e(t)+'</span>'}
async function jfetch(u){try{const r=await fetch(u);return r.ok?r.json():null}catch{return null}}
function cnt(id,n){const el=document.getElementById(id);if(el)el.textContent=n+' row(s)'}
function ft(tid,q){
  const tb=document.getElementById(tid);if(!tb)return;
  const rows=tb.tBodies[0].rows;const lq=q.toLowerCase();let v=0;
  for(const r of rows){const s=!q||r.textContent.toLowerCase().includes(lq);r.style.display=s?'':'none';if(s)v++;}
  cnt('c-'+tid.replace('tbl-',''),v);
}
function svcMode(m){svcF=m;['all','run','stp'].forEach(x=>{document.getElementById('fb-'+x).classList.toggle('on',x===m||(m==='running'&&x==='run')||(m==='stopped'&&x==='stp'))});svcSearch()}
function svcSearch(){
  const q=document.getElementById('s-svc').value.toLowerCase();
  const rows=document.getElementById('tbl-svc').tBodies[0].rows;let v=0;
  for(const r of rows){
    const st=r.dataset.st||'';
    const mok=svcF==='all'||(svcF==='running'&&st==='Running')||(svcF==='stopped'&&st==='Stopped');
    const sok=!q||r.textContent.toLowerCase().includes(q);
    const s=mok&&sok;r.style.display=s?'':'none';if(s)v++;
  }
  cnt('c-svc',v);
}
function certMode(m){certF=m;['all','exp','xp'].forEach(x=>{document.getElementById('cb-'+x).classList.toggle('on',x===m||(m==='EXPIRED'&&x==='exp')||(m==='EXPIRING'&&x==='xp'))});certSearch()}
function certSearch(){
  const q=document.getElementById('s-cert').value.toLowerCase();
  const rows=document.getElementById('tbl-cert').tBodies[0].rows;let v=0;
  for(const r of rows){
    const st=r.dataset.st||'';
    const mok=certF==='all'||st===certF;
    const sok=!q||r.textContent.toLowerCase().includes(q);
    const s=mok&&sok;r.style.display=s?'':'none';if(s)v++;
  }
  cnt('c-cert',v);
}
async function loadHealth(){
  const d=await jfetch('/api/health');if(!d)return;
  document.getElementById('hdr-meta').innerHTML=e(d.hostname)+' &nbsp;|&nbsp; '+e(d.username)+'<br>'+e(d.timestamp);
  const cards=[
    {label:'CPU',val:d.cpu+'%',sub:'Processor load',pct:d.cpu},
    {label:'Memory',val:d.ramPct+'%',sub:d.ramUsed+' / '+d.ramTotal+' GB',pct:d.ramPct},
    {label:'Uptime',val:e(d.uptime),sub:'Since last boot',pct:-1},
  ];
  document.getElementById('cards').innerHTML=cards.map(c=>`
    <div class="card">
      <div class="cl">${c.label}</div>
      <div class="cv" style="color:${c.pct>=0?pclr(c.pct):'var(--acc)'};font-size:${c.pct<0?'20px':'26px'}">${c.val}</div>
      <div class="cs">${c.sub}</div>
      ${c.pct>=0?`<div class="pbar"><div class="fill" style="width:${c.pct}%;background:${pclr(c.pct)}"></div></div>`:''}
    </div>`).join('')+(d.disks||[]).map(dk=>`
    <div class="card">
      <div class="cl">Drive ${e(dk.drive)}</div>
      <div class="cv" style="color:${pclr(dk.used)}">${dk.used}%</div>
      <div class="cs">${dk.free} GB free / ${dk.size} GB</div>
      <div class="pbar"><div class="fill" style="width:${dk.used}%;background:${pclr(dk.used)}"></div></div>
    </div>`).join('');
}
async function loadProcesses(){
  const d=await jfetch('/api/processes');if(!d)return;
  const tb=document.getElementById('tbl-proc').tBodies[0];tb.innerHTML='';
  d.forEach(p=>{const r=tb.insertRow();r.innerHTML=`<td class="ok">${e(p.name)}</td><td class="muted">${p.pid}</td><td>${p.cpu}</td><td>${p.ram}</td><td>${p.threads}</td><td class="muted" title="${e(p.path)}">${e(p.path)}</td>`;});
  cnt('c-proc',d.length);
}
async function loadServices(){
  const d=await jfetch('/api/services');if(!d)return;svcAll=d;
  const tb=document.getElementById('tbl-svc').tBodies[0];tb.innerHTML='';
  d.forEach(s=>{const run=s.status==='Running';const r=tb.insertRow();r.dataset.st=s.status;r.innerHTML=`<td class="${run?'ok':'muted'}">${e(s.name)}</td><td>${e(s.display)}</td><td>${badge(s.status,run?'ok':'muted')}</td><td class="muted">${e(s.start)}</td>`;});
  cnt('c-svc',d.length);svcSearch();
}
async function loadEvents(){
  const d=await jfetch('/api/events');if(!d)return;
  const tb=document.getElementById('tbl-evt').tBodies[0];tb.innerHTML='';
  d.forEach(ev=>{const cl=ev.level==='Critical'||ev.level==='Error'?'err':ev.level==='Warning'?'warn':'muted';const r=tb.insertRow();r.innerHTML=`<td class="muted">${e(ev.time)}</td><td>${ev.id}</td><td class="${cl}">${e(ev.level)}</td><td>${e(ev.source)}</td><td title="${e(ev.message)}">${e(ev.message)}</td>`;});
  cnt('c-evt',d.length);
}
async function loadPorts(){
  const d=await jfetch('/api/ports');if(!d)return;
  const tb=document.getElementById('tbl-port').tBodies[0];tb.innerHTML='';
  d.forEach(p=>{const r=tb.insertRow();r.innerHTML=`<td style="color:${p.proto==='TCP'?'var(--acc)':'var(--warn)'}">${p.proto}</td><td class="muted">${e(p.addr)}</td><td class="ok">${p.port}</td><td class="muted">${e(p.state)}</td><td class="muted">${p.pid}</td><td>${e(p.process)}</td><td class="muted" title="${e(p.path)}">${e(p.path)}</td>`;});
  cnt('c-port',d.length);
}
async function loadCerts(){
  const d=await jfetch('/api/certs');if(!d)return;certAll=d;
  const tb=document.getElementById('tbl-cert').tBodies[0];tb.innerHTML='';
  d.forEach(c=>{const cl=c.status==='EXPIRED'?'err':c.status==='EXPIRING'?'warn':'ok';const r=tb.insertRow();r.dataset.st=c.status;r.innerHTML=`<td class="muted">${e(c.store)}</td><td>${e(c.subject)}</td><td class="muted">${e(c.issuer)}</td><td class="muted">${e(c.expires)}</td><td class="${cl}">${c.days}</td><td>${badge(c.status,cl)}</td>`;});
  cnt('c-cert',d.length);certSearch();
}
async function loadTasks(){
  const d=await jfetch('/api/tasks');if(!d)return;
  const tb=document.getElementById('tbl-task').tBodies[0];tb.innerHTML='';
  if(!d.length){const r=tb.insertRow();r.insertCell(0).colSpan=5;r.cells[0].innerHTML='<span class="ok" style="padding:14px;display:block">&#10003; No failed scheduled tasks</span>';return;}
  d.forEach(t=>{const r=tb.insertRow();r.innerHTML=`<td class="err">${e(t.name)}</td><td class="muted">${e(t.path)}</td><td>${e(t.state)}</td><td class="muted">${e(t.lastrun)}</td><td class="err">${e(t.lastresult)}</td>`;});
}
function buildApi(){
  const host=window.location.host;
  const eps=[
    ['/api/health',   'System health — CPU, RAM, disk, uptime'],
    ['/api/processes','Top 25 processes by CPU usage'],
    ['/api/services', 'All Windows services with status and start type'],
    ['/api/events',   'Recent System + Application errors (last 24 h)'],
    ['/api/ports',    'All listening TCP/UDP ports with owning process'],
    ['/api/certs',    'Certificate store scan (LocalMachine hive)'],
    ['/api/tasks',    'Failed / errored scheduled tasks'],
  ];
  document.getElementById('api-list').innerHTML=eps.map(([u,d])=>`
    <div class="api-card">
      <div><span class="method">GET</span>&nbsp;<a href="${u}" target="_blank">http://${host}${u}</a></div>
      <div class="desc">${d}</div>
    </div>`).join('');
  document.getElementById('tab-api').querySelector('pre').textContent=
    'Invoke-RestMethod http://'+host+'/api/health | ConvertTo-Json\nInvoke-RestMethod http://'+host+'/api/services | Where-Object status -eq \'Stopped\'';
}
var loaders={health:loadHealth,processes:loadProcesses,services:loadServices,events:loadEvents,ports:loadPorts,certs:loadCerts,tasks:loadTasks,api:buildApi};
function showTab(t){
  curTab=t;
  document.querySelectorAll('nav button').forEach(b=>{b.classList.toggle('active',b.textContent.trim().toLowerCase().replace(/\s.*/,'')===t||(t==='api'&&b.textContent.includes('API')))});
  document.querySelectorAll('.section').forEach(s=>{s.classList.toggle('active',s.id==='tab-'+t)});
  if(loaders[t])loaders[t]();
}
async function refreshAll(){
  document.getElementById('last-ref').textContent='Refreshing…';
  await loadHealth();
  if(curTab!=='health'&&loaders[curTab])await loaders[curTab]();
  document.getElementById('last-ref').textContent='Refreshed '+new Date().toLocaleTimeString();
}
function toggleAuto(on){if(autoT)clearInterval(autoT);if(on)autoT=setInterval(refreshAll,30000)}
window.addEventListener('DOMContentLoaded',()=>{document.getElementById('srv-lbl').textContent='Connected — '+window.location.host;buildApi();refreshAll();toggleAuto(true)});
</script>
</body></html>
'@
}

function Start-WebServer {
    param([int]$Port=8080)
    if($script:webData['Running']){
        [System.Windows.Forms.MessageBox]::Show("Already running on port $Port.`nBrowse to: http://localhost:$Port","Web Dashboard")
        return
    }
    $sLbl.Text='Collecting dashboard data…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Refresh-WebData
    # Store HTML inside the shared hashtable — avoids null-variable issues across runspaces
    $script:webData['HTML'] = Get-DashboardHtml
    $script:webData['Running'] = $true
    $script:webData['Port']    = $Port
    $script:webData['Listener']= $null

    $script:webRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:webRS.Open()
    $script:webRS.SessionStateProxy.SetVariable('data', $script:webData)
    $script:webRS.SessionStateProxy.SetVariable('port', $Port)

    $script:webPS = [System.Management.Automation.PowerShell]::Create()
    $script:webPS.Runspace = $script:webRS
    [void]$script:webPS.AddScript({
        $lst = New-Object System.Net.HttpListener
        # Try all-interfaces first (needs elevation), fall back to localhost-only
        try   { $lst.Prefixes.Add("http://+:$port/"); $lst.Start() }
        catch {
            $lst.Prefixes.Clear()
            try { $lst.Prefixes.Add("http://localhost:$port/"); $lst.Start() }
            catch { $data['Running']=$false; return }
        }
        $data['Listener'] = $lst   # share listener so Stop-WebServer can call .Stop()

        while($data['Running']){
            $ctx = $null
            try { $ctx = $lst.GetContext() }   # blocks until a request arrives
            catch { break }                     # HttpListenerException when Stop() is called
            if($null -eq $ctx){ continue }

            # Always close the response in a finally — prevents browser from spinning forever
            try {
                $path   = $ctx.Request.Url.AbsolutePath.ToLower().TrimEnd('/')
                $isApi  = $path.StartsWith('/api/')
                # if/elseif instead of switch to guarantee a value is always assigned
                $body   = if     ($path -eq '/api/health')   { $data['Health']    }
                          elseif ($path -eq '/api/processes') { $data['Processes'] }
                          elseif ($path -eq '/api/services')  { $data['Services']  }
                          elseif ($path -eq '/api/events')    { $data['Events']    }
                          elseif ($path -eq '/api/ports')     { $data['Ports']     }
                          elseif ($path -eq '/api/certs')     { $data['Certs']     }
                          elseif ($path -eq '/api/tasks')     { $data['Tasks']     }
                          else                                { $data['HTML']      }
                if(-not $body){ $body = if($isApi){'{}'}else{'<p>Loading…</p>'} }
                $ct    = if($isApi){'application/json; charset=utf-8'}else{'text/html; charset=utf-8'}
                $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$body)
                $ctx.Response.ContentType     = $ct
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.AddHeader('Access-Control-Allow-Origin','*')
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            } finally {
                try { $ctx.Response.OutputStream.Close() } catch {}
            }
        }
        try { $lst.Stop(); $lst.Close() } catch {}
    })
    [void]$script:webPS.BeginInvoke()

    # Wait up to 3 s for the listener to actually start
    $waited = 0
    while($null -eq $script:webData['Listener'] -and $waited -lt 3000){
        Start-Sleep -Milliseconds 100; $waited += 100
        [System.Windows.Forms.Application]::DoEvents()
    }

    if($script:webData['Running'] -and $null -ne $script:webData['Listener']){
        $btnWebSrv.Text = '⬡ Stop Web Server'; $btnWebSrv.BackColor = $C.DkRed
        $webTimer.Start()
        $url = "http://localhost:$Port"
        $sLbl.Text = "Web dashboard running → $url   (URL copied to clipboard)"
        try{ [System.Windows.Forms.Clipboard]::SetText($url) }catch{}
    } else {
        $script:webData['Running'] = $false
        $sLbl.Text = "Failed to start web server on port $Port — try running as Administrator"
    }
}

function Stop-WebServer {
    $webTimer.Stop()
    $script:webData['Running'] = $false
    try { $script:webData['Listener'].Stop() } catch {}   # unblocks GetContext()
    Start-Sleep -Milliseconds 600
    try { $script:webPS.Stop(); $script:webPS.Dispose() } catch {}
    try { $script:webRS.Close(); $script:webRS.Dispose() } catch {}
    $script:webPS = $null; $script:webRS = $null
    $script:webData['Listener'] = $null
    $btnWebSrv.Text = '⬡ Web Dashboard'; $btnWebSrv.BackColor = $C.DkGreen
    $sLbl.Text = 'Web server stopped.'
}

# ═══════════════════════════════════════════════════════════════════════════
# EVENT HANDLERS
# ═══════════════════════════════════════════════════════════════════════════

# Health
$btnRefH.Add_Click({ Update-Health })

# Events
$btnEvGo.Add_Click({ Load-Events })
$gEv.Add_SelectionChanged({
    if($gEv.SelectedRows.Count -gt 0 -and $script:evtData){
        $i=$gEv.SelectedRows[0].Index
        if($i -ge 0 -and $i -lt $script:evtData.Count){
            $e=$script:evtData[$i]
            $rtbEvD.Text="Time   : $($e.TimeCreated)`r`nID     : $($e.Id)`r`nLevel  : $($e.LevelDisplayName)`r`nSource : $($e.ProviderName)`r`n`r`nMessage:`r`n$($e.Message)"
        }
    }
})
$btnEvExp.Add_Click({
    if(-not $script:evtData){[System.Windows.Forms.MessageBox]::Show('No events loaded.','Export');return}
    $dlg=New-Object System.Windows.Forms.SaveFileDialog; $dlg.Filter='CSV|*.csv'
    $dlg.FileName="Events_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    if($dlg.ShowDialog() -eq 'OK'){
        $script:evtData|Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message|Export-Csv $dlg.FileName -NoTypeInformation
        [System.Windows.Forms.MessageBox]::Show("Saved: $($dlg.FileName)",'Export OK')
    }
})

# Network
$btnNPing.Add_Click({
    $t=$txtNTgt.Text.Trim(); $rtbNet.Text="Pinging $t…"; $form.Refresh()
    $r=Test-Connection $t -Count 4 -EA SilentlyContinue
    if($r){
        $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine("Ping: $t")|Out-Null; $sb.AppendLine('─'*55)|Out-Null
        foreach($p in $r){$sb.AppendLine("  $($p.Address)   $($p.ResponseTime) ms   TTL $($p.TimeToLive)")|Out-Null}
        $sb.AppendLine('')|Out-Null; $sb.AppendLine("  Average: $([math]::Round(($r|Measure-Object ResponseTime -Average).Average,1)) ms")|Out-Null
        $rtbNet.Text=$sb.ToString()
    }else{$rtbNet.Text="UNREACHABLE: $t"}
})
$btnNTrc.Add_Click({
    $t=$txtNTgt.Text.Trim(); $rtbNet.Text="Traceroute to $t  (may take ~30s)…"; $form.Refresh()
    try{
        $tr=Test-NetConnection $t -TraceRoute -EA Stop
        $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine("Traceroute: $t")|Out-Null; $sb.AppendLine('─'*55)|Out-Null
        $hop=1; foreach($h in $tr.TraceRoute){$sb.AppendLine("  $([string]$hop).  $h")|Out-Null;$hop++}
        $rtbNet.Text=$sb.ToString()
    }catch{$rtbNet.Text="Failed: $_"}
})
$btnNAdp.Add_Click({
    $rtbNet.Text='Loading…'; $form.Refresh()
    $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine('═══ IP-Enabled Adapters ═══')|Out-Null; $sb.AppendLine('')|Out-Null
    foreach($n in (Get-Nets)){
        $sb.AppendLine("  Adapter : $($n.Description)")|Out-Null
        $sb.AppendLine("  IP(s)   : $($n.IPAddress -join ', ')")|Out-Null
        $sb.AppendLine("  Gateway : $($n.DefaultIPGateway -join ', ')")|Out-Null
        $sb.AppendLine("  MAC     : $($n.MACAddress)")|Out-Null
        $sb.AppendLine("  DHCP    : $($n.DHCPEnabled)")|Out-Null; $sb.AppendLine('')|Out-Null
    }
    $rtbNet.Text=$sb.ToString()
})
$btnNTCP.Add_Click({
    $rtbNet.Text='Loading TCP connections…'; $form.Refresh()
    try{
        $cc=Get-NetTCPConnection -State Established -EA Stop|Sort-Object RemoteAddress
        $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine('═══ Established TCP Connections ═══')|Out-Null; $sb.AppendLine('')|Out-Null
        $sb.AppendLine(("{0,-22}{1,-8}{2,-22}{3,-8}{4}" -f 'Local Addr','LPort','Remote Addr','RPort','PID'))|Out-Null
        $sb.AppendLine('─'*75)|Out-Null
        foreach($c in $cc){$sb.AppendLine(("{0,-22}{1,-8}{2,-22}{3,-8}{4}" -f $c.LocalAddress,$c.LocalPort,$c.RemoteAddress,$c.RemotePort,$c.OwningProcess))|Out-Null}
        $rtbNet.Text=$sb.ToString()
    }catch{$rtbNet.Text="Error: $_"}
})
$btnNDnsC.Add_Click({
    $rtbNet.Text='Loading DNS cache…'; $form.Refresh()
    try{
        $en=Get-DnsClientCache -EA Stop|Sort-Object Name
        $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine('═══ DNS Client Cache ═══')|Out-Null; $sb.AppendLine('')|Out-Null
        $sb.AppendLine(("{0,-50}{1,-12}{2,-8}{3}" -f 'Name','Type','TTL','Data'))|Out-Null; $sb.AppendLine('─'*90)|Out-Null
        foreach($e in $en){$sb.AppendLine(("{0,-50}{1,-12}{2,-8}{3}" -f $e.Name,$e.Type,$e.TTL,$e.Data))|Out-Null}
        $rtbNet.Text=$sb.ToString()
    }catch{$rtbNet.Text="Error: $_"}
})
$btnNRte.Add_Click({
    $rtbNet.Text='Loading route table…'; $form.Refresh()
    try{
        $rt=Get-NetRoute -EA Stop|Where-Object DestinationPrefix -notmatch '255\.255\.255\.255'|Sort-Object InterfaceAlias
        $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine('═══ Route Table ═══')|Out-Null; $sb.AppendLine('')|Out-Null
        $sb.AppendLine(("{0,-32}{1,-20}{2,-24}{3,-8}{4}" -f 'Destination','NextHop','Interface','Metric','Protocol'))|Out-Null; $sb.AppendLine('─'*95)|Out-Null
        foreach($r in $rt){$sb.AppendLine(("{0,-32}{1,-20}{2,-24}{3,-8}{4}" -f $r.DestinationPrefix,$r.NextHop,$r.InterfaceAlias,$r.RouteMetric,$r.Protocol))|Out-Null}
        $rtbNet.Text=$sb.ToString()
    }catch{$rtbNet.Text="Error: $_"}
})
$btnDNSGo.Add_Click({
    $nm=$txtDNSNm.Text.Trim(); if(-not $nm){[System.Windows.Forms.MessageBox]::Show('Enter a hostname.','DNS');return}
    $sv=$txtDNSSv.Text.Trim(); $tp=$cmbDNST.SelectedItem
    $rtbNet.Text="Resolving $nm ($tp)$(if($sv){" via $sv"})…"; $form.Refresh()
    $res=Test-DNS $nm $sv $tp
    if($res.OK){
        $sb=[System.Text.StringBuilder]::new(); $sb.AppendLine("DNS: $nm  [$tp]$(if($sv){" via $sv"})")|Out-Null; $sb.AppendLine('─'*65)|Out-Null
        foreach($r in $res.R){$sb.AppendLine("  $($r.Name.PadRight(45)) $($r.Type.ToString().PadRight(8)) TTL:$($r.TTL.ToString().PadRight(8)) $($r.IPAddress)")|Out-Null}
        $rtbNet.Text=$sb.ToString()
    }else{$rtbNet.Text="DNS FAILED:`n$($res.Err)"}
})

# Port Testing — preset buttons
foreach($pName in $PortPresets.Keys){
    $script:pBtns[$pName].Add_Click({
        $pn=$this.Tag; $tgt=$txtPTgt.Text.Trim()
        if(-not $tgt){[System.Windows.Forms.MessageBox]::Show('Enter a target host.','Port Test');return}
        $tests=$PortPresets[$pn]|ForEach-Object{$_+@{Group=$pn}}
        Run-Ports $tgt $tests
    })
}
$btnCTest.Add_Click({
    $tgt=$txtPTgt.Text.Trim(); if(-not $tgt){[System.Windows.Forms.MessageBox]::Show('Enter a target.','Port Test');return}
    $raw=$txtCPort.Text -split '[,;\s]+' | Where-Object{$_ -match '^\d+$'}
    if(-not $raw){[System.Windows.Forms.MessageBox]::Show('Enter port numbers.','Port Test');return}
    $proto=$cmbCProto.SelectedItem
    $tests=$raw|ForEach-Object{@{N="Port $_"; P=[int]$_; Proto=$proto; Group='Custom'}}
    Run-Ports $tgt $tests
})
$btnPTAll.Add_Click({
    $tgt=$txtPTgt.Text.Trim(); if(-not $tgt){[System.Windows.Forms.MessageBox]::Show('Enter a target.','Port Test');return}
    if([System.Windows.Forms.MessageBox]::Show("Run ALL presets against $tgt?  This tests $( ($PortPresets.Values|Measure-Object Count -Sum).Sum ) ports.","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo) -ne 'Yes'){return}
    $all=@(); foreach($k in $PortPresets.Keys){$all+=$PortPresets[$k]|ForEach-Object{$_+@{Group=$k}}}
    Run-Ports $tgt $all
})
$btnPTClr.Add_Click({ $gPT.Rows.Clear() })

# Permissions — NTFS
$btnNFGet.Add_Click({
    $path=$txtNFPath.Text.Trim(); $sLbl.Text="Reading ACL…"; $form.Refresh()
    $perms=Get-NTFS $path
    $dt=New-DT @('Identity','Type','Rights','Inherited','InheritFlags','PropFlags')
    foreach($p in $perms){
        $r=$dt.NewRow(); $r['Identity']=$p.IdentityReference; $r['Type']=$p.Type
        $r['Rights']=$p.Rights; $r['Inherited']=$p.Inherited
        $r['InheritFlags']=$p.InheritFlags; $r['PropFlags']=$p.PropFlags; $dt.Rows.Add($r)
    }
    $gNF.DataSource=$null; $gNF.Columns.Clear(); $gNF.DataSource=$dt
    foreach($row in $gNF.Rows){
        if($null -eq $row -or $null -eq $row.Cells['Type'] -or $row.Cells['Type'].Value -is [System.DBNull]){continue}
        if($row.Cells['Type'].Value.ToString() -eq 'Deny'){ $row.DefaultCellStyle.ForeColor=$C.Err }
        else{ $row.DefaultCellStyle.ForeColor=$C.White }
    }
    try{$rtbNF.Text=(& icacls $path 2>&1|Out-String)}catch{$rtbNF.Text='icacls failed.'}
    $sLbl.Text='Ready'
})
$btnNFBr.Add_Click({
    $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.SelectedPath=$txtNFPath.Text
    if($d.ShowDialog() -eq 'OK'){$txtNFPath.Text=$d.SelectedPath; $btnNFGet.PerformClick()}
})
$btnNFIcl.Add_Click({
    try{$rtbNF.Text=(& icacls $txtNFPath.Text.Trim() 2>&1|Out-String)}catch{$rtbNF.Text="icacls failed: $_"}
})

# Permissions — Shares
$btnShrLoad.Add_Click({
    $sLbl.Text='Loading shares…'; $form.Refresh()
    $shares=Get-Shares
    $dt=New-DT @('Name','Path','Description')
    foreach($s in $shares){$r=$dt.NewRow(); $r['Name']=$s.Name; $r['Path']=$s.Path; $r['Description']=$s.Description; $dt.Rows.Add($r)}
    $gShr.DataSource=$null; $gShr.Columns.Clear(); $gShr.DataSource=$dt
    $sLbl.Text='Ready'
})
$gShr.Add_SelectionChanged({
    if($gShr.SelectedRows.Count -gt 0){
        $name=$gShr.SelectedRows[0].Cells['Name'].Value
        if($name){
            $perms=Get-SharePerms $name
            $dt=New-DT @('Account','AccessRight','AccessControlType')
            foreach($p in $perms){
                $r=$dt.NewRow(); $r['Account']=$p.AccountName; $r['AccessRight']=$p.AccessRight
                $r['AccessControlType']=$p.AccessControlType; $dt.Rows.Add($r)
            }
            $gShrP.DataSource=$null; $gShrP.Columns.Clear(); $gShrP.DataSource=$dt
        }
    }
})

# Permissions — Access Test
$btnAccBr.Add_Click({
    $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.SelectedPath=$txtAccP.Text
    if($d.ShowDialog() -eq 'OK'){$txtAccP.Text=$d.SelectedPath}
})
$btnAccT.Add_Click({
    $rtbAcc.Text='Testing…'; $form.Refresh()
    $rtbAcc.Text=Test-Access $txtAccP.Text.Trim()
})

# Permissions — User Groups
$btnGrpLoad.Add_Click({
    $sLbl.Text='Loading groups…'; $form.Refresh()
    $groups=Get-MyGroups
    $sb=[System.Text.StringBuilder]::new()
    $sb.AppendLine("Token groups for: $env:USERDOMAIN\$env:USERNAME")|Out-Null
    $sb.AppendLine("Date: $(Get-Date)")|Out-Null; $sb.AppendLine('─'*65)|Out-Null
    foreach($g in $groups){$sb.AppendLine("  $g")|Out-Null}
    $sb.AppendLine('')|Out-Null; $sb.AppendLine("Total: $($groups.Count) groups")|Out-Null
    $rtbGrp.Text=$sb.ToString(); $sLbl.Text='Ready'
})

# Services
$btnSvcRef.Add_Click({ Load-Services })
$btnSvcSta.Add_Click({
    if($gSvc.SelectedRows.Count -eq 0){return}
    $n=$gSvc.SelectedRows[0].Cells['Name'].Value
    try{Start-Service $n -EA Stop; Load-Services; $sLbl.Text="Started: $n"}
    catch{[System.Windows.Forms.MessageBox]::Show("Could not start '$n'`n$($_.Exception.Message)",'Error')}
})
$btnSvcStp.Add_Click({
    if($gSvc.SelectedRows.Count -eq 0){return}
    $n=$gSvc.SelectedRows[0].Cells['Name'].Value
    if([System.Windows.Forms.MessageBox]::Show("Stop service '$n'?","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo) -eq 'Yes'){
        try{Stop-Service $n -Force -EA Stop; Load-Services; $sLbl.Text="Stopped: $n"}
        catch{[System.Windows.Forms.MessageBox]::Show("Could not stop '$n'`n$($_.Exception.Message)",'Error')}
    }
})
$btnSvcRst.Add_Click({
    if($gSvc.SelectedRows.Count -eq 0){return}
    $n=$gSvc.SelectedRows[0].Cells['Name'].Value
    if([System.Windows.Forms.MessageBox]::Show("Restart service '$n'?","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo) -eq 'Yes'){
        try{Restart-Service $n -Force -EA Stop; Load-Services; $sLbl.Text="Restarted: $n"}
        catch{[System.Windows.Forms.MessageBox]::Show("Could not restart '$n'`n$($_.Exception.Message)",'Error')}
    }
})
$txtSvcF.Add_TextChanged({ Load-Services })
$cmbSvcSt.Add_SelectedIndexChanged({ Load-Services })

# Security
$btnSecLoad.Add_Click({ Load-Security })

# New tab event handlers
$btnSILoad.Add_Click({ Load-SysInfo })
$btnUpdHist.Add_Click({ Load-UpdateHistory })
$btnUpdPend.Add_Click({ Load-PendingUpdates })
$btnCertScan.Add_Click({ Load-Certs })
$cmbCertFilter.Add_SelectedIndexChanged({ if($script:certData){Load-Certs} })
$btnTaskLoad.Add_Click({ Load-Tasks })
$cmbTaskFilter.Add_SelectedIndexChanged({ if($script:taskData){Load-Tasks} })
$btnAutoLoad.Add_Click({ Load-Autoruns })
$btnRelLoad.Add_Click({ Load-Reliability })
$gRel.Add_SelectionChanged({
    if($gRel.SelectedRows.Count -gt 0 -and $script:relData){
        $i=$gRel.SelectedRows[0].Index
        if($i -ge 0 -and $i -lt $script:relData.Count){
            $rtbRel.Text="Time   : $($script:relData[$i].Time)`r`nType   : $($script:relData[$i].Type)`r`nSource : $($script:relData[$i].Source)`r`n`r`nMessage:`r`n$($script:relData[$i].Message)"
        }
    }
})
$btnADLoad.Add_Click({
    $sLbl.Text='Running AD health checks…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $rtbAD.Text=Get-ADHealthInfo; $sLbl.Text='Ready'
})
$btnGPOLoad.Add_Click({
    $sLbl.Text='Running gpresult /r /scope user…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $rtbGPO.Text=& gpresult /r /scope user /f 2>&1 | Out-String; $sLbl.Text='Ready'
})
$btnGPOComp.Add_Click({
    $sLbl.Text='Running gpresult /r /scope computer…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $rtbGPO.Text=& gpresult /r /scope computer /f 2>&1 | Out-String; $sLbl.Text='Ready'
})
$btnISCSILoad.Add_Click({
    $sLbl.Text='Loading storage info…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $rtbISCSI.Text=Get-iSCSIInfo; $sLbl.Text='Ready'
})
$btnSSLCheck.Add_Click({
    $h=$txtSSLHost.Text.Trim(); if(-not $h){[System.Windows.Forms.MessageBox]::Show('Enter a hostname.','SSL');return}
    Load-SSL $h ([int]$numSSLPort.Value)
})

# Tab 18 — Listening Ports
$btnLPLoad.Add_Click({ Load-ListeningPorts })
$btnLPSrch.Add_Click({ Load-ListeningPorts })

# Tab 19 — Ping Sweep
$btnPSSweep.Add_Click({ Start-PingSweep })
$btnPSStop.Add_Click({ $script:psSweeping=$false })

# Tab 20 — Net Details
$btnNDLoad.Add_Click({ Load-NetDetails })

# Tab 21 — Installed Software
$btnISLoad.Add_Click({ Load-InstalledSoftware ($txtISF.Text.Trim()) })
$btnISSrch.Add_Click({ Load-InstalledSoftware ($txtISF.Text.Trim()) })

# Tab 22 — IIS / Activation
$btnIISLoad.Add_Click({ Load-IISHealth })
$btnActLoad.Add_Click({
    $sLbl.Text='Running slmgr /dli…'; $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $rtbAct.Text=Get-WinActivation; $sLbl.Text='Ready'
})

# Tab 23 — Performance+
$btnPerfRef.Add_Click({ Load-PerfAll })
$chkPerfLive.Add_CheckedChanged({
    if($chkPerfLive.Checked){ $perfTimer.Start() }else{ $perfTimer.Stop() }
})

# Web Dashboard button
$btnWebSrv.Add_Click({
    if($script:webData['Running']){ Stop-WebServer }
    else{ Start-WebServer 8080 }
})

# ─── Timer + startup ──────────────────────────────────────────────────────────
$timer=New-Object System.Windows.Forms.Timer; $timer.Interval=30000
$timer.Add_Tick({ if($chkAuto.Checked -and $tabs.SelectedTab -eq $tabH){ Update-Health } })
$timer.Start()

$perfTimer=New-Object System.Windows.Forms.Timer; $perfTimer.Interval=3000
$perfTimer.Add_Tick({ if($tabs.SelectedTab -eq $tabPerf){ Load-PerfAll } })

# Web data refresh timer (60s, only active while server is running)
$webTimer=New-Object System.Windows.Forms.Timer; $webTimer.Interval=60000
$webTimer.Add_Tick({
    if($script:webData['Running']){
        try { Refresh-WebData } catch {}
    } else { $webTimer.Stop() }
})

$form.Add_Shown({
    $script:formReady=$true
    Update-Health
    Load-Services
})
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    $perfTimer.Stop(); $perfTimer.Dispose()
    $webTimer.Stop(); $webTimer.Dispose()
    if($script:webData['Running']){ Stop-WebServer }
})

[System.Windows.Forms.Application]::Run($form)
