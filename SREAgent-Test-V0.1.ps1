#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function Get-CPUUsage {
    (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
}

function Get-MemoryInfo {
    $os    = Get-CimInstance Win32_OperatingSystem
    $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $free  = [math]::Round($os.FreePhysicalMemory  / 1MB, 2)
    $used  = [math]::Round($total - $free, 2)
    @{ Total = $total; Used = $used; Free = $free; Percent = [math]::Round(($used/$total)*100,1) }
}

function Get-GPUInfo {
    Get-CimInstance Win32_VideoController |
        Select-Object Name, AdapterRAM, CurrentRefreshRate, VideoModeDescription
}

function Get-NetworkAdapters {
    Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled } |
        Select-Object Description, IPAddress, DefaultIPGateway, MACAddress, DHCPEnabled
}

function Get-DiskInfo {
    Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } |
        Select-Object DeviceID,
            @{N='Size(GB)'; E={[math]::Round($_.Size/1GB,1)}},
            @{N='Free(GB)'; E={[math]::Round($_.FreeSpace/1GB,1)}},
            @{N='Used%';    E={[math]::Round((($_.Size-$_.FreeSpace)/$_.Size)*100,1)}}
}

function Get-FilteredEvents {
    param([string]$LogName, [string]$Level, [int]$Hours, [int]$MaxEvents=500)
    $filter = @{ LogName = $LogName; StartTime = (Get-Date).AddHours(-$Hours) }
    if ($Level -ne 'All') {
        $map = @{ Critical=1; Error=2; Warning=3; Information=4 }
        if ($map.ContainsKey($Level)) { $filter['Level'] = $map[$Level] }
    }
    try { Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -EA Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message }
    catch { @() }
}

# ─────────────────────────────────────────────────────────────────────────────
# Colour palette
# ─────────────────────────────────────────────────────────────────────────────

$C = @{
    BgDark   = [System.Drawing.Color]::FromArgb(15, 15, 26)
    BgMid    = [System.Drawing.Color]::FromArgb(22, 22, 38)
    BgCard   = [System.Drawing.Color]::FromArgb(30, 30, 52)
    BgBar    = [System.Drawing.Color]::FromArgb(25, 25, 42)
    Accent   = [System.Drawing.Color]::FromArgb(0,  200, 255)
    White    = [System.Drawing.Color]::White
    Muted    = [System.Drawing.Color]::FromArgb(130, 130, 160)
    Ok       = [System.Drawing.Color]::FromArgb(80,  220, 120)
    Warn     = [System.Drawing.Color]::FromArgb(255, 190,  50)
    Error    = [System.Drawing.Color]::FromArgb(255,  80,  80)
    Blue     = [System.Drawing.Color]::FromArgb(0,   120, 180)
    Green    = [System.Drawing.Color]::FromArgb(40,  110,  40)
    GridLine = [System.Drawing.Color]::FromArgb(45,  45,  68)
}

function ColorForPct($pct) {
    if ($pct -gt 85) { $C.Error } elseif ($pct -gt 65) { $C.Warn } else { $C.Ok }
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Form
# ─────────────────────────────────────────────────────────────────────────────

$form = New-Object System.Windows.Forms.Form
$form.Text          = "SRE Agent  —  Windows Diagnostics"
$form.Size          = New-Object System.Drawing.Size(1150, 780)
$form.MinimumSize   = New-Object System.Drawing.Size(950, 660)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $C.BgDark
$form.ForeColor     = $C.White
$form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)

# Title bar
$pnlTitle = New-Object System.Windows.Forms.Panel
$pnlTitle.Dock      = "Top"
$pnlTitle.Height    = 52
$pnlTitle.BackColor = $C.BgCard

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "  SRE Agent  |  Windows Diagnostics"
$lblTitle.ForeColor = $C.Accent
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize  = $true
$lblTitle.Dock      = "Left"
$lblTitle.Padding   = New-Object System.Windows.Forms.Padding(12, 10, 0, 0)

$lblHost = New-Object System.Windows.Forms.Label
$lblHost.Text       = "  $env:COMPUTERNAME  |  $env:USERNAME  "
$lblHost.ForeColor  = $C.Muted
$lblHost.AutoSize   = $true
$lblHost.Dock       = "Right"
$lblHost.Padding    = New-Object System.Windows.Forms.Padding(0, 16, 16, 0)

$pnlTitle.Controls.AddRange(@($lblTitle, $lblHost))

# Tab control
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock        = "Fill"
$tabs.Appearance  = "Normal"
$tabs.Font        = New-Object System.Drawing.Font("Segoe UI", 9)

# Status strip
$strip    = New-Object System.Windows.Forms.StatusStrip
$strip.BackColor = $C.BgBar
$sLabel   = New-Object System.Windows.Forms.ToolStripStatusLabel
$sLabel.ForeColor = $C.Muted
$sLabel.Text      = "Ready"
$strip.Items.Add($sLabel) | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Helper: metric card
# ─────────────────────────────────────────────────────────────────────────────

function New-Card([string]$title) {
    $card = New-Object System.Windows.Forms.Panel
    $card.Size      = New-Object System.Drawing.Size(245, 118)
    $card.BackColor = $C.BgCard
    $card.Margin    = New-Object System.Windows.Forms.Padding(0,0,12,0)

    $lTitle = New-Object System.Windows.Forms.Label
    $lTitle.Text      = $title
    $lTitle.ForeColor = $C.Accent
    $lTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $lTitle.Location  = New-Object System.Drawing.Point(12, 10)
    $lTitle.AutoSize  = $true

    $lVal = New-Object System.Windows.Forms.Label
    $lVal.Text      = "—"
    $lVal.ForeColor = $C.White
    $lVal.Font      = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
    $lVal.Location  = New-Object System.Drawing.Point(12, 32)
    $lVal.AutoSize  = $true
    $lVal.Tag       = "val"

    $lSub = New-Object System.Windows.Forms.Label
    $lSub.Text      = "Loading..."
    $lSub.ForeColor = $C.Muted
    $lSub.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lSub.Location  = New-Object System.Drawing.Point(12, 84)
    $lSub.AutoSize  = $true
    $lSub.Tag       = "sub"

    $card.Controls.AddRange(@($lTitle, $lVal, $lSub))
    $card
}

function Set-CardValue($card, [string]$val, [string]$sub, $color) {
    $v = $card.Controls | Where-Object Tag -eq 'val'
    $s = $card.Controls | Where-Object Tag -eq 'sub'
    $v.Text      = $val
    $v.ForeColor = $color
    $s.Text      = $sub
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: styled DataGridView
# ─────────────────────────────────────────────────────────────────────────────

function New-Grid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.BackgroundColor                              = $C.BgMid
    $g.ForeColor                                    = $C.White
    $g.GridColor                                    = $C.GridLine
    $g.BorderStyle                                  = "None"
    $g.DefaultCellStyle.BackColor                   = $C.BgMid
    $g.DefaultCellStyle.ForeColor                   = $C.White
    $g.DefaultCellStyle.SelectionBackColor          = [System.Drawing.Color]::FromArgb(0,100,150)
    $g.DefaultCellStyle.SelectionForeColor          = $C.White
    $g.AlternatingRowsDefaultCellStyle.BackColor    = [System.Drawing.Color]::FromArgb(28,28,46)
    $g.ColumnHeadersDefaultCellStyle.BackColor      = $C.BgCard
    $g.ColumnHeadersDefaultCellStyle.ForeColor      = $C.Accent
    $g.ColumnHeadersHeight                          = 28
    $g.RowHeadersVisible                            = $false
    $g.AllowUserToAddRows                           = $false
    $g.ReadOnly                                     = $true
    $g.SelectionMode                                = "FullRowSelect"
    $g.MultiSelect                                  = $false
    $g
}

# ─────────────────────────────────────────────────────────────────────────────
# TAB 1 — System Health
# ─────────────────────────────────────────────────────────────────────────────

$tabHealth            = New-Object System.Windows.Forms.TabPage
$tabHealth.Text       = "  System Health  "
$tabHealth.BackColor  = $C.BgDark
$tabHealth.ForeColor  = $C.White

# Metric cards row
$flowCards = New-Object System.Windows.Forms.FlowLayoutPanel
$flowCards.Dock          = "Top"
$flowCards.Height        = 138
$flowCards.BackColor     = $C.BgDark
$flowCards.Padding       = New-Object System.Windows.Forms.Padding(10,10,0,0)
$flowCards.FlowDirection = "LeftToRight"

$cardCPU  = New-Card "CPU Usage"
$cardMEM  = New-Card "Memory"
$cardDisk = New-Card "Disk  C:"
$cardGPU  = New-Card "GPU"
$flowCards.Controls.AddRange(@($cardCPU, $cardMEM, $cardDisk, $cardGPU))

# Disk detail grid
$lblDiskHdr = New-Object System.Windows.Forms.Label
$lblDiskHdr.Text      = "  All Drives"
$lblDiskHdr.Dock      = "Top"
$lblDiskHdr.Height    = 26
$lblDiskHdr.ForeColor = $C.Accent
$lblDiskHdr.Font      = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$lblDiskHdr.BackColor = $C.BgBar

$grdDisk = New-Grid
$grdDisk.Dock              = "Top"
$grdDisk.Height            = 110
$grdDisk.AutoSizeColumnsMode = "Fill"

# GPU / Network info
$lblInfoHdr = New-Object System.Windows.Forms.Label
$lblInfoHdr.Text      = "  GPU  &  Network Adapters"
$lblInfoHdr.Dock      = "Top"
$lblInfoHdr.Height    = 26
$lblInfoHdr.ForeColor = $C.Accent
$lblInfoHdr.Font      = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$lblInfoHdr.BackColor = $C.BgBar

$rtbInfo = New-Object System.Windows.Forms.RichTextBox
$rtbInfo.Dock        = "Fill"
$rtbInfo.BackColor   = $C.BgMid
$rtbInfo.ForeColor   = [System.Drawing.Color]::FromArgb(200,210,230)
$rtbInfo.Font        = New-Object System.Drawing.Font("Consolas",9)
$rtbInfo.ReadOnly    = $true
$rtbInfo.BorderStyle = "None"

# Footer
$pnlHealthFoot = New-Object System.Windows.Forms.Panel
$pnlHealthFoot.Dock      = "Bottom"
$pnlHealthFoot.Height    = 38
$pnlHealthFoot.BackColor = $C.BgBar

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = "Refresh Now"
$btnRefresh.Size      = New-Object System.Drawing.Size(108, 26)
$btnRefresh.Location  = New-Object System.Drawing.Point(10, 6)
$btnRefresh.BackColor = $C.Blue
$btnRefresh.ForeColor = $C.White
$btnRefresh.FlatStyle = "Flat"
$btnRefresh.FlatAppearance.BorderSize = 0

$lblUpdated = New-Object System.Windows.Forms.Label
$lblUpdated.Text      = "Last refreshed: —"
$lblUpdated.ForeColor = $C.Muted
$lblUpdated.AutoSize  = $true
$lblUpdated.Location  = New-Object System.Drawing.Point(128, 11)

$chkAutoRefresh = New-Object System.Windows.Forms.CheckBox
$chkAutoRefresh.Text      = "Auto-refresh (30s)"
$chkAutoRefresh.Checked   = $true
$chkAutoRefresh.ForeColor = $C.Muted
$chkAutoRefresh.AutoSize  = $true
$chkAutoRefresh.Location  = New-Object System.Drawing.Point(320, 10)

$pnlHealthFoot.Controls.AddRange(@($btnRefresh, $lblUpdated, $chkAutoRefresh))

$tabHealth.Controls.AddRange(@($pnlHealthFoot, $rtbInfo, $lblInfoHdr, $grdDisk, $lblDiskHdr, $flowCards))

# ─────────────────────────────────────────────────────────────────────────────
# TAB 2 — Event Viewer
# ─────────────────────────────────────────────────────────────────────────────

$tabEvents           = New-Object System.Windows.Forms.TabPage
$tabEvents.Text      = "  Event Viewer  "
$tabEvents.BackColor = $C.BgDark
$tabEvents.ForeColor = $C.White

# Filter bar
$pnlFilter = New-Object System.Windows.Forms.Panel
$pnlFilter.Dock      = "Top"
$pnlFilter.Height    = 50
$pnlFilter.BackColor = $C.BgBar

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $text
    $l.ForeColor = $C.White
    $l.Location  = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize  = $true
    $l
}
function New-Combo($items, $x, $w) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Items.AddRange($items)
    $c.SelectedIndex = 0
    $c.Location      = New-Object System.Drawing.Point($x, 13)
    $c.Width         = $w
    $c.FlatStyle     = "Flat"
    $c.BackColor     = [System.Drawing.Color]::FromArgb(38,38,60)
    $c.ForeColor     = $C.White
    $c.DropDownStyle = "DropDownList"
    $c
}

$cmbLog   = New-Combo @('System','Application','Security','Setup','Microsoft-Windows-PowerShell/Operational') 45 280
$cmbLevel = New-Combo @('All','Critical','Error','Warning','Information') 380 120
$numHours = New-Object System.Windows.Forms.NumericUpDown
$numHours.Minimum  = 1; $numHours.Maximum = 720; $numHours.Value = 24
$numHours.Location = New-Object System.Drawing.Point(595, 13)
$numHours.Width    = 65
$numHours.BackColor = [System.Drawing.Color]::FromArgb(38,38,60)
$numHours.ForeColor = $C.White

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text      = "Search"
$btnSearch.Location  = New-Object System.Drawing.Point(675, 12)
$btnSearch.Size      = New-Object System.Drawing.Size(80, 26)
$btnSearch.BackColor = $C.Blue
$btnSearch.ForeColor = $C.White
$btnSearch.FlatStyle = "Flat"
$btnSearch.FlatAppearance.BorderSize = 0

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text      = "Export CSV"
$btnExport.Location  = New-Object System.Drawing.Point(765, 12)
$btnExport.Size      = New-Object System.Drawing.Size(88, 26)
$btnExport.BackColor = $C.Green
$btnExport.ForeColor = $C.White
$btnExport.FlatStyle = "Flat"
$btnExport.FlatAppearance.BorderSize = 0

$pnlFilter.Controls.AddRange(@(
    (New-Label "Log:"       10  16), $cmbLog,
    (New-Label "Level:"    335  16), $cmbLevel,
    (New-Label "Last (hrs):" 512 16), $numHours,
    $btnSearch, $btnExport
))

# Status label
$lblEvtStatus = New-Object System.Windows.Forms.Label
$lblEvtStatus.Text      = "  Ready — choose filters and click Search"
$lblEvtStatus.Dock      = "Bottom"
$lblEvtStatus.Height    = 24
$lblEvtStatus.ForeColor = $C.Muted
$lblEvtStatus.BackColor = $C.BgBar
$lblEvtStatus.Font      = New-Object System.Drawing.Font("Segoe UI",8)

# Split: grid top, detail bottom
$splitEvt = New-Object System.Windows.Forms.SplitContainer
$splitEvt.Dock             = "Fill"
$splitEvt.Orientation      = "Horizontal"
$splitEvt.SplitterDistance = 340
$splitEvt.BackColor        = $C.BgDark

$grdEvt = New-Grid
$grdEvt.Dock = "Fill"

$rtbDetail = New-Object System.Windows.Forms.RichTextBox
$rtbDetail.Dock        = "Fill"
$rtbDetail.BackColor   = [System.Drawing.Color]::FromArgb(18,18,32)
$rtbDetail.ForeColor   = [System.Drawing.Color]::FromArgb(200,225,200)
$rtbDetail.Font        = New-Object System.Drawing.Font("Consolas",9)
$rtbDetail.ReadOnly    = $true
$rtbDetail.BorderStyle = "None"
$rtbDetail.Text        = "Select a row above to view the full event message."

$splitEvt.Panel1.Controls.Add($grdEvt)
$splitEvt.Panel2.Controls.Add($rtbDetail)

$tabEvents.Controls.AddRange(@($lblEvtStatus, $splitEvt, $pnlFilter))

# ─────────────────────────────────────────────────────────────────────────────
# TAB 3 — Network
# ─────────────────────────────────────────────────────────────────────────────

$tabNet           = New-Object System.Windows.Forms.TabPage
$tabNet.Text      = "  Network  "
$tabNet.BackColor = $C.BgDark
$tabNet.ForeColor = $C.White

$pnlNetBar = New-Object System.Windows.Forms.Panel
$pnlNetBar.Dock      = "Top"
$pnlNetBar.Height    = 48
$pnlNetBar.BackColor = $C.BgBar

function New-NetBtn($text, $x, $bg) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $text
    $b.Size      = New-Object System.Drawing.Size(140,28)
    $b.Location  = New-Object System.Drawing.Point($x,10)
    $b.BackColor = $bg
    $b.ForeColor = $C.White
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b
}

$txtPingTarget = New-Object System.Windows.Forms.TextBox
$txtPingTarget.Text       = "8.8.8.8"
$txtPingTarget.Location   = New-Object System.Drawing.Point(10,14)
$txtPingTarget.Width      = 145
$txtPingTarget.BackColor  = [System.Drawing.Color]::FromArgb(38,38,60)
$txtPingTarget.ForeColor  = $C.White
$txtPingTarget.BorderStyle = "FixedSingle"

$btnPing       = New-NetBtn "Ping"           165 $C.Blue
$btnAdapters   = New-NetBtn "Adapters"       315 [System.Drawing.Color]::FromArgb(55,55,95)
$btnNetstat    = New-NetBtn "TCP Connections" 465 [System.Drawing.Color]::FromArgb(55,55,95)
$btnDNS        = New-NetBtn "DNS Cache"      615 [System.Drawing.Color]::FromArgb(55,55,95)

$pnlNetBar.Controls.AddRange(@($txtPingTarget, $btnPing, $btnAdapters, $btnNetstat, $btnDNS))

$rtbNet = New-Object System.Windows.Forms.RichTextBox
$rtbNet.Dock        = "Fill"
$rtbNet.BackColor   = $C.BgMid
$rtbNet.ForeColor   = [System.Drawing.Color]::FromArgb(200,225,200)
$rtbNet.Font        = New-Object System.Drawing.Font("Consolas",9)
$rtbNet.ReadOnly    = $true
$rtbNet.BorderStyle = "None"
$rtbNet.Text        = "Use the buttons above to run network diagnostics."

$tabNet.Controls.AddRange(@($rtbNet, $pnlNetBar))

# ─────────────────────────────────────────────────────────────────────────────
# Assemble
# ─────────────────────────────────────────────────────────────────────────────

$tabs.TabPages.AddRange(@($tabHealth, $tabEvents, $tabNet))

$pnlMain = New-Object System.Windows.Forms.Panel
$pnlMain.Dock = "Fill"
$pnlMain.Controls.Add($tabs)

$form.Controls.AddRange(@($pnlMain, $pnlTitle, $strip))

# ─────────────────────────────────────────────────────────────────────────────
# Logic
# ─────────────────────────────────────────────────────────────────────────────

$script:evtRows = @()

function Update-Health {
    $sLabel.Text = "Refreshing…"; $form.Refresh()

    # CPU
    $cpu = [math]::Round((Get-CPUUsage),1)
    Set-CardValue $cardCPU "$cpu%" "Processor load" (ColorForPct $cpu)

    # Memory
    $m = Get-MemoryInfo
    Set-CardValue $cardMEM "$($m.Percent)%" "$($m.Used) / $($m.Total) GB used" (ColorForPct $m.Percent)

    # Disk C:
    $disks = Get-DiskInfo
    $c = $disks | Where-Object DeviceID -eq 'C:'
    if ($c) {
        Set-CardValue $cardDisk "$($c.'Used%')%" "$($c.'Free(GB)') GB free / $($c.'Size(GB)') GB" (ColorForPct $c.'Used%')
    }

    # GPU (just show name — no load via WMI without extra tool)
    $gpus = Get-GPUInfo
    $g    = if ($gpus -is [array]) { $gpus[0] } else { $gpus }
    $gpuName = if ($g.Name.Length -gt 22) { $g.Name.Substring(0,22)+"…" } else { $g.Name }
    $gpuRAM  = if ($g.AdapterRAM) { "$([math]::Round($g.AdapterRAM/1GB,1)) GB VRAM" } else { "VRAM N/A" }
    Set-CardValue $cardGPU "OK" "$gpuName  |  $gpuRAM" $C.Ok

    # Disk grid
    $grdDisk.DataSource = $null; $grdDisk.Columns.Clear()
    $dt = New-Object System.Data.DataTable
    'Drive','Size (GB)','Free (GB)','Used %' | ForEach-Object { $dt.Columns.Add($_) | Out-Null }
    foreach ($d in $disks) {
        $r = $dt.NewRow()
        $r['Drive']     = $d.DeviceID
        $r['Size (GB)'] = $d.'Size(GB)'
        $r['Free (GB)'] = $d.'Free(GB)'
        $r['Used %']    = "$($d.'Used%')%"
        $dt.Rows.Add($r)
    }
    $grdDisk.DataSource = $dt

    # GPU + network text
    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("═══ GPU ═══") | Out-Null
    foreach ($gi in $gpus) {
        $ram = if ($gi.AdapterRAM) { "$([math]::Round($gi.AdapterRAM/1GB,1)) GB" } else { "N/A" }
        $sb.AppendLine("  Name       : $($gi.Name)") | Out-Null
        $sb.AppendLine("  VRAM       : $ram") | Out-Null
        $sb.AppendLine("  Resolution : $($gi.VideoModeDescription)") | Out-Null
        $sb.AppendLine("") | Out-Null
    }
    $sb.AppendLine("═══ Network Adapters ═══") | Out-Null
    foreach ($n in (Get-NetworkAdapters)) {
        $sb.AppendLine("  Adapter : $($n.Description)") | Out-Null
        $sb.AppendLine("  IP(s)   : $($n.IPAddress  -join ', ')") | Out-Null
        $sb.AppendLine("  Gateway : $($n.DefaultIPGateway -join ', ')") | Out-Null
        $sb.AppendLine("  MAC     : $($n.MACAddress)") | Out-Null
        $sb.AppendLine("  DHCP    : $($n.DHCPEnabled)") | Out-Null
        $sb.AppendLine("") | Out-Null
    }
    $rtbInfo.Text = $sb.ToString()

    $lblUpdated.Text = "Last refreshed: $(Get-Date -Format 'HH:mm:ss')"
    $sLabel.Text = "Ready"
}

function Load-Events {
    $sLabel.Text = "Querying event log…"; $form.Refresh()
    $script:evtRows = Get-FilteredEvents -LogName $cmbLog.SelectedItem `
                                          -Level   $cmbLevel.SelectedItem `
                                          -Hours   ([int]$numHours.Value)

    $grdEvt.DataSource = $null; $grdEvt.Columns.Clear()
    $dt = New-Object System.Data.DataTable
    'Time','ID','Level','Source','Message' | ForEach-Object { $dt.Columns.Add($_) | Out-Null }
    foreach ($e in $script:evtRows) {
        $r = $dt.NewRow()
        $r['Time']    = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        $r['ID']      = $e.Id
        $r['Level']   = $e.LevelDisplayName
        $r['Source']  = $e.ProviderName
        $r['Message'] = ($e.Message -split "`n")[0] -replace '\s+',' '
        $dt.Rows.Add($r)
    }
    $grdEvt.DataSource = $dt

    if ($grdEvt.Columns.Count -ge 5) {
        $grdEvt.Columns['Time'].Width    = 148
        $grdEvt.Columns['ID'].Width      =  55
        $grdEvt.Columns['Level'].Width   =  95
        $grdEvt.Columns['Source'].Width  = 210
        $grdEvt.Columns['Message'].Width = 550
    }

    foreach ($row in $grdEvt.Rows) {
        $row.DefaultCellStyle.ForeColor = switch ($row.Cells['Level'].Value) {
            'Critical'    { $C.Error }
            'Error'       { [System.Drawing.Color]::FromArgb(255,110,110) }
            'Warning'     { $C.Warn  }
            default       { [System.Drawing.Color]::FromArgb(200,205,225) }
        }
    }

    $lblEvtStatus.Text = "  $($script:evtRows.Count) event(s)  |  $($cmbLog.SelectedItem)  |  last $($numHours.Value) hrs"
    $sLabel.Text = "Ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# Event handlers
# ─────────────────────────────────────────────────────────────────────────────

$btnRefresh.Add_Click({ Update-Health })

$btnSearch.Add_Click({ Load-Events })

$grdEvt.Add_SelectionChanged({
    if ($grdEvt.SelectedRows.Count -gt 0) {
        $i = $grdEvt.SelectedRows[0].Index
        if ($i -ge 0 -and $i -lt $script:evtRows.Count) {
            $e = $script:evtRows[$i]
            $rtbDetail.Text = "Time   : $($e.TimeCreated)`r`nID     : $($e.Id)`r`nLevel  : $($e.LevelDisplayName)`r`nSource : $($e.ProviderName)`r`n`r`nMessage:`r`n$($e.Message)"
        }
    }
})

$btnExport.Add_Click({
    if (-not $script:evtRows) { [System.Windows.Forms.MessageBox]::Show("No events loaded.","Export"); return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = "CSV Files (*.csv)|*.csv"
    $dlg.FileName = "Events_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:evtRows | Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message |
            Export-Csv -Path $dlg.FileName -NoTypeInformation
        [System.Windows.Forms.MessageBox]::Show("Saved to:`n$($dlg.FileName)", "Export Complete")
    }
})

$btnPing.Add_Click({
    $target = $txtPingTarget.Text.Trim()
    $rtbNet.Text = "Pinging $target …`r`n"; $form.Refresh()
    $res = Test-Connection -ComputerName $target -Count 4 -EA SilentlyContinue
    if ($res) {
        $sb = [System.Text.StringBuilder]::new()
        $sb.AppendLine("Ping: $target") | Out-Null
        $sb.AppendLine("─"*55) | Out-Null
        foreach ($r in $res) { $sb.AppendLine("  $($r.Address)   RTT: $($r.ResponseTime) ms   TTL: $($r.TimeToLive)") | Out-Null }
        $avg = [math]::Round(($res | Measure-Object ResponseTime -Average).Average, 1)
        $sb.AppendLine("`r`n  Average RTT: $avg ms") | Out-Null
        $rtbNet.Text = $sb.ToString()
    } else {
        $rtbNet.Text = "UNREACHABLE: $target"
    }
})

$btnAdapters.Add_Click({
    $rtbNet.Text = "Loading…"; $form.Refresh()
    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("═══ IP-Enabled Adapters ═══`r`n") | Out-Null
    foreach ($n in (Get-NetworkAdapters)) {
        $sb.AppendLine("  Adapter : $($n.Description)") | Out-Null
        $sb.AppendLine("  IP(s)   : $($n.IPAddress -join ', ')") | Out-Null
        $sb.AppendLine("  Gateway : $($n.DefaultIPGateway -join ', ')") | Out-Null
        $sb.AppendLine("  MAC     : $($n.MACAddress)") | Out-Null
        $sb.AppendLine("  DHCP    : $($n.DHCPEnabled)`r`n") | Out-Null
    }
    $rtbNet.Text = $sb.ToString()
})

$btnNetstat.Add_Click({
    $rtbNet.Text = "Loading TCP connections…"; $form.Refresh()
    try {
        $conns = Get-NetTCPConnection -State Established -EA Stop |
            Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,OwningProcess |
            Sort-Object RemoteAddress
        $sb = [System.Text.StringBuilder]::new()
        $sb.AppendLine("═══ Established TCP Connections ═══`r`n") | Out-Null
        $sb.AppendLine(("{0,-22}{1,-8}{2,-22}{3,-8}{4}" -f "Local Addr","LPort","Remote Addr","RPort","PID")) | Out-Null
        $sb.AppendLine("─"*75) | Out-Null
        foreach ($c in $conns) {
            $sb.AppendLine(("{0,-22}{1,-8}{2,-22}{3,-8}{4}" -f $c.LocalAddress,$c.LocalPort,$c.RemoteAddress,$c.RemotePort,$c.OwningProcess)) | Out-Null
        }
        $rtbNet.Text = $sb.ToString()
    } catch { $rtbNet.Text = "Error: $_" }
})

$btnDNS.Add_Click({
    $rtbNet.Text = "Loading DNS cache…"; $form.Refresh()
    try {
        $entries = Get-DnsClientCache -EA Stop | Sort-Object Name | Select-Object Name,Type,TTL,Data
        $sb = [System.Text.StringBuilder]::new()
        $sb.AppendLine("═══ DNS Client Cache ═══`r`n") | Out-Null
        $sb.AppendLine(("{0,-50}{1,-12}{2,-8}{3}" -f "Name","Type","TTL","Data")) | Out-Null
        $sb.AppendLine("─"*90) | Out-Null
        foreach ($e in $entries) {
            $sb.AppendLine(("{0,-50}{1,-12}{2,-8}{3}" -f $e.Name,$e.Type,$e.TTL,$e.Data)) | Out-Null
        }
        $rtbNet.Text = $sb.ToString()
    } catch { $rtbNet.Text = "Error: $_" }
})

# Auto-refresh timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.Add_Tick({
    if ($chkAutoRefresh.Checked -and $tabs.SelectedTab -eq $tabHealth) { Update-Health }
})
$timer.Start()

$form.Add_Shown({ Update-Health })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

[System.Windows.Forms.Application]::Run($form)
