# KeyHunt Segment Scanner v3 - WPF dashboard (monitor + launcher)
# Save as: C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3-gui.ps1
#
# Run:
#   Double-click Run-V3-GUI.cmd
#   powershell -NoProfile -ExecutionPolicy Bypass -File "...\Wrappers\v3-gui.ps1"
#
# Design: v3.ps1 + KeyHunt-Cuda.exe run in a separate process. This window only
# polls resume/log files. GPU scan speed is effectively unchanged (~0% overhead).

param(
    [string]$suiteRoot = "C:\Users\Admin\Documents\KeyhuntSuite"
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$wrapperDir  = Join-Path $suiteRoot "Wrappers"
$v3Script    = Join-Path $wrapperDir "v3.ps1"
$segmentFile = Join-Path $suiteRoot "segment71_10000.txt"
$scanDir     = Join-Path $suiteRoot "Scanned_Segments"
$foundLog    = Join-Path $scanDir "Found_All.txt"
$liveFeedFile = Join-Path $scanDir "live_feed.jsonl"
$statusFile  = Join-Path $scanDir "status.json"
$logFile     = Join-Path $wrapperDir "runner.log"
$mutexName   = "Global\KeyHuntSegmentScanner"

$script:ScanProcess = $null
$script:LastLogOffset = 0L
$script:LastLiveFeedOffset = 0L
$script:LiveRowNum = 0
$script:LiveRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:SpeedSamples = [System.Collections.Generic.Queue[double]]::new()
$script:KeysGenerated = [System.Numerics.BigInteger]::Zero

function HexToBig([string]$h) {
    $clean = ($h -replace '\s', '').Trim()
    if ($clean -match '^0x') { $clean = $clean.Substring(2) }
    if (!$clean) { return [System.Numerics.BigInteger]::Zero }
    [System.Numerics.BigInteger]::Parse("0" + $clean, [System.Globalization.NumberStyles]::HexNumber)
}

function BigToHex([System.Numerics.BigInteger]$n) { $n.ToString("X") }

function Format-Big([System.Numerics.BigInteger]$n) {
    if ($n -lt 1000) { return $n.ToString() }
    $s = $n.ToString()
    $neg = $s.StartsWith('-')
    if ($neg) { $s = $s.Substring(1) }
    $parts = New-Object System.Collections.Generic.List[string]
    while ($s.Length -gt 3) {
        $parts.Insert(0, $s.Substring($s.Length - 3))
        $s = $s.Substring(0, $s.Length - 3)
    }
    if ($s) { $parts.Insert(0, $s) }
    $joined = ($parts -join ',')
    if ($neg) { return "-$joined" }
    return $joined
}

function Format-Rate([double]$rate) {
    if ($rate -ge 1e9) { return "{0:N2}G/s" -f ($rate / 1e9) }
    if ($rate -ge 1e6) { return "{0:N2}M/s" -f ($rate / 1e6) }
    if ($rate -ge 1e3) { return "{0:N0}/s" -f $rate }
    if ($rate -le 0) { return "—" }
    return "{0:N1}/s" -f $rate
}

function Format-Duration([double]$seconds) {
    if ($seconds -le 0 -or [double]::IsInfinity($seconds) -or [double]::IsNaN($seconds)) { return "—" }
    if ($seconds -lt 3600) { return "{0:N1}m" -f ($seconds / 60) }
    if ($seconds -lt 86400) { return "{0:N1}h" -f ($seconds / 3600) }
    return "{0:N1}d" -f ($seconds / 86400)
}

function Parse-SegmentRange([string]$line) {
    $line = $line.Trim()
    if (!$line -or $line.StartsWith('#')) { return $null }
    if ($line -match ':') { $parts = $line.Split(':') }
    elseif ($line -match ',') {
        $parts = $line.Split(',')
        if ($parts.Count -ge 3) { $parts = @($parts[1], $parts[2]) }
    }
    else { return $null }
    if ($parts.Count -lt 2) { return $null }
    return @{ Start = $parts[0].Trim(); End = $parts[1].Trim() }
}

function Parse-ResumeLine([string]$line) {
    if (!$line) { return $null }
    $line = $line.Trim()
    if ($line -match '^(\d+),(\d+),([0-9A-Fa-f]+),([0-9A-Fa-f]+),(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})$') {
        return @{
            SegIdx    = [int]$Matches[1]
            SubIdx    = [int]$Matches[2]
            StartHex  = $Matches[3]
            EndHex    = $Matches[4]
            Timestamp = [datetime]::ParseExact($Matches[5], 'MM/dd/yyyy HH:mm:ss', $null)
        }
    }
    return $null
}

function Get-ScannerRunning {
    try {
        $m = [System.Threading.Mutex]::OpenExisting($mutexName)
        $owned = $m.WaitOne(0)
        if ($owned) { $m.ReleaseMutex() }
        $m.Dispose()
        return -not $owned
    }
    catch {
        return $false
    }
}

function Get-LatestResumeForSegment([int]$segIdx) {
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    if (!(Test-Path $resumeFile)) { return $null }
    $best = $null
    foreach ($line in @(Get-Content $resumeFile -ErrorAction SilentlyContinue)) {
        $p = Parse-ResumeLine $line
        if (!$p -or $p.SegIdx -ne $segIdx) { continue }
        if (!$best -or $p.SubIdx -gt $best.SubIdx -or ($p.SubIdx -eq $best.SubIdx -and $p.Timestamp -gt $best.Timestamp)) {
            $best = $p
        }
    }
    return $best
}

function Get-SpeedFromLog {
    if (!(Test-Path $logFile)) { return 0.0 }
    $lines = Get-Content $logFile -Tail 80 -ErrorAction SilentlyContinue
    $chunkStart = $null
    foreach ($line in $lines) {
        if ($line -match 'SEG (\d+) SUB (\d+)/\d+ chunk ([0-9A-Fa-f]+):([0-9A-Fa-f]+)') {
            $chunkStart = Get-Date
        }
        elseif ($chunkStart -and $line -match 'KeyHunt finished in ([0-9,\.]+)s exit 0') {
            $secs = [double]($Matches[1] -replace ',', '')
            if ($secs -gt 0) { return 0.0 } # speed computed from resume below when possible
        }
    }
    return 0.0
}

function Update-Metrics {
    $segIdx = 0
    [void][int]::TryParse($txtStartIndex.Text, [ref]$segIdx)

    $range = $null
    $segTotal = [System.Numerics.BigInteger]::Zero
    if (Test-Path $segmentFile) {
        $segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith('#') })
        if ($segIdx -ge 0 -and $segIdx -lt $segments.Count) {
            $range = Parse-SegmentRange $segments[$segIdx]
        }
    }

    if ($range) {
        $txtRangeStart.Text = $range.Start
        $txtRangeEnd.Text = $range.End
        $segStart = HexToBig $range.Start
        $segEnd = HexToBig $range.End
        $segTotal = $segEnd - $segStart + 1

        $resume = Get-LatestResumeForSegment $segIdx
        if ($resume -and $resume.EndHex) {
            $pos = HexToBig $resume.EndHex
            if ($pos -ge $segStart) {
                $done = $pos - $segStart + 1
                if ($done -lt 0) { $done = [System.Numerics.BigInteger]::Zero }
                if ($segTotal -gt 0) {
                    $pct = [double](($done * 1000) / $segTotal) / 10.0
                    if ($pct -gt 100) { $pct = 100 }
                    $barSegment.Value = $pct
                    $lblSegmentPct.Text = "{0:N2}%" -f $pct
                    $remaining = $segTotal - $done
                    if ($remaining -lt 0) { $remaining = [System.Numerics.BigInteger]::Zero }
                    $script:KeysGenerated = $done
                }
                $txtCurrentChunk.Text = "$($resume.StartHex):$($resume.EndHex)"
                $lblSub.Text = "SUB $($resume.SubIdx)"
            }
        }
        else {
            $barSegment.Value = 0
            $lblSegmentPct.Text = "0.00%"
            $lblSub.Text = "SUB —"
            $txtCurrentChunk.Text = "—"
        }
    }

    $running = Get-ScannerRunning
    if ($running) {
        $lblStatus.Text = "Scanning (v3.ps1 + KeyHunt CUDA)..."
        $lblStatus.Foreground = '#FF1B7F3A'
        $btnStart.IsEnabled = $false
        $btnStop.IsEnabled = $true
    }
    else {
        $lblStatus.Text = "Idle — press Start or Space"
        $lblStatus.Foreground = '#FF666666'
        $btnStart.IsEnabled = $true
        $btnStop.IsEnabled = $false
    }

    # Speed from last two resume lines (same segment)
    $speed = 0.0
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    if (Test-Path $resumeFile) {
        $entries = @()
        foreach ($line in @(Get-Content $resumeFile -ErrorAction SilentlyContinue)) {
            $p = Parse-ResumeLine $line
            if ($p -and $p.SegIdx -eq $segIdx -and $p.EndHex) { $entries += $p }
        }
        if ($entries.Count -ge 2) {
            $a = $entries[$entries.Count - 2]
            $b = $entries[$entries.Count - 1]
            $dt = ($b.Timestamp - $a.Timestamp).TotalSeconds
            if ($dt -gt 0) {
                $keys = HexToBig $b.EndHex - HexToBig $a.EndHex
                if ($keys -gt 0) {
                    $speed = [double]$keys / $dt
                    $script:SpeedSamples.Enqueue($speed)
                    while ($script:SpeedSamples.Count -gt 8) { [void]$script:SpeedSamples.Dequeue() }
                }
            }
        }
    }
    if ($script:SpeedSamples.Count -gt 0) {
        $speed = ($script:SpeedSamples | Measure-Object -Average).Average
    }

    if (Test-Path $statusFile) {
        try {
            $st = Get-Content $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($st.speed -and [double]$st.speed -gt 0) {
                $speed = [double]$st.speed
                $script:SpeedSamples.Enqueue($speed)
                while ($script:SpeedSamples.Count -gt 8) { [void]$script:SpeedSamples.Dequeue() }
            }
        }
        catch { }
    }

    $lblGenerated.Text = Format-Big $script:KeysGenerated
    $lblSpeed.Text = Format-Rate $speed
    $lblWorkers.Text = "1 CUDA"

    $matchCount = 0
    if (Test-Path $foundLog) {
        $matchCount = @(Get-Content $foundLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
    }
    $lblMatch.Text = $matchCount.ToString()

    if ($range -and $speed -gt 0 -and $segTotal -gt 0) {
        $resume = Get-LatestResumeForSegment $segIdx
        $done = [System.Numerics.BigInteger]::Zero
        if ($resume -and $resume.EndHex) {
            $done = HexToBig $resume.EndHex - HexToBig $range.Start + 1
        }
        $remaining = $segTotal - $done
        if ($remaining -gt 0) {
            $lblEta.Text = Format-Duration ([double]$remaining / $speed)
        }
        else { $lblEta.Text = "—" }
    }
    else { $lblEta.Text = "—" }

    Update-LogTail
}

function Update-LiveTable {
    if (!(Test-Path $liveFeedFile)) { return }
    try {
        $fs = [System.IO.File]::Open($liveFeedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -lt $script:LastLiveFeedOffset) {
            $script:LastLiveFeedOffset = 0
            $script:LiveRows.Clear()
            $script:LiveRowNum = 0
        }
        $read = $len - $script:LastLiveFeedOffset
        if ($read -le 0) { $fs.Dispose(); return }
        $fs.Seek($script:LastLiveFeedOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buf = New-Object byte[] $read
        [void]$fs.Read($buf, 0, $read)
        $script:LastLiveFeedOffset = $len
        $fs.Dispose()
        $text = [System.Text.Encoding]::UTF8.GetString($buf)
        foreach ($line in ($text -split "`n")) {
            $line = $line.Trim()
            if (!$line) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $script:LiveRowNum++
                $matchText = if ($o.match) { "YES" } else { "" }
                $row = [pscustomobject]@{
                    Num       = $script:LiveRowNum
                    PrivKey   = [string]$o.priv
                    Address   = [string]$o.address
                    Balance   = if ($o.balance) { [string]$o.balance } else { "-" }
                    Received  = if ($o.received) { [string]$o.received } else { "-" }
                    Match     = $matchText
                    IsMatch   = [bool]$o.match
                }
                $script:LiveRows.Add($row)
                while ($script:LiveRows.Count -gt 200) { $script:LiveRows.RemoveAt(0) }
            }
            catch { }
        }
        if ($dgLive.ItemsSource -ne $script:LiveRows) {
            $dgLive.ItemsSource = $script:LiveRows
        }
        if ($script:LiveRows.Count -gt 0) {
            $dgLive.ScrollIntoView($script:LiveRows[$script:LiveRows.Count - 1])
        }
    }
    catch { }
}

function Update-FoundTable {
    # Match count comes from Found_All.txt in Update-Metrics
}

function Update-LogTail {
    if (!(Test-Path $logFile)) { return }
    try {
        $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -lt $script:LastLogOffset) { $script:LastLogOffset = 0 }
        $read = [Math]::Min(12000, $len - $script:LastLogOffset)
        if ($read -gt 0) {
            $fs.Seek($script:LastLogOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] $read
            [void]$fs.Read($buf, 0, $read)
            $script:LastLogOffset = $len
            $text = [System.Text.Encoding]::UTF8.GetString($buf)
            if ($txtLog.Text.Length -gt 20000) {
                $txtLog.Text = $txtLog.Text.Substring($txtLog.Text.Length - 12000)
            }
            $txtLog.AppendText($text)
            $txtLog.ScrollToEnd()
        }
        $fs.Dispose()
    }
    catch { }
}

function Start-Scanner {
    if (!(Test-Path $v3Script)) {
        [System.Windows.MessageBox]::Show("v3.ps1 not found:`n$v3Script", "KeyHunt v3", 'OK', 'Error') | Out-Null
        return
    }
    if (Get-ScannerRunning) { return }

    $script:LastLiveFeedOffset = 0L
    $script:LiveRows.Clear()
    $script:LiveRowNum = 0

    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $v3Script,
        '-startIndex', $txtStartIndex.Text,
        '-saveIntervalHours', $txtSaveHours.Text
    )
    if ($chkAutoStart.IsChecked) { $args += '-RegisterAutoStart' }
    if ($txtStartSub.Text -match '^\d+$') { $args += @('-startSub', $txtStartSub.Text) }

    $modeItem = $cmbMode.SelectedItem
    $modeVal = if ($modeItem -is [System.Windows.Controls.ComboBoxItem]) { $modeItem.Content } else { 'uncompressed' }
    $args += @('-mode', [string]$modeVal)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($args | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join ' '
    $psi.WorkingDirectory = $wrapperDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
  $script:ScanProcess = [System.Diagnostics.Process]::Start($psi)
}

function Stop-Scanner {
    if ($script:ScanProcess -and !$script:ScanProcess.HasExited) {
        $script:ScanProcess.Kill()
        $script:ScanProcess = $null
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'KeyHunt-Cuda.exe' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="KeyHunt Segment Scanner v3" Height="860" Width="1180"
        Background="#FFF3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="160"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="White" CornerRadius="8" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="220"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="0,0,8,0">
          <TextBlock Text="Segment range (read-only)" FontWeight="SemiBold" Margin="0,0,0,4"/>
          <TextBlock Text="Start" Foreground="#666" FontSize="11"/>
          <TextBox x:Name="txtRangeStart" IsReadOnly="True" FontFamily="Consolas" Margin="0,2,0,6"/>
          <TextBlock Text="End" Foreground="#666" FontSize="11"/>
          <TextBox x:Name="txtRangeEnd" IsReadOnly="True" FontFamily="Consolas"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Margin="0,0,8,0">
          <TextBlock Text="Current chunk" FontWeight="SemiBold" Margin="0,0,0,4"/>
          <TextBox x:Name="txtCurrentChunk" IsReadOnly="True" FontFamily="Consolas" Margin="0,0,0,8"/>
          <TextBlock x:Name="lblSub" Text="SUB —" Foreground="#2563EB" FontWeight="SemiBold"/>
          <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
            <TextBlock Text="Segment progress" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="lblSegmentPct" Text="0.00%" Foreground="#2563EB" FontWeight="Bold" VerticalAlignment="Center"/>
          </StackPanel>
          <ProgressBar x:Name="barSegment" Height="14" Margin="0,6,0,0" Maximum="100"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="Scanner settings" FontWeight="SemiBold" Margin="0,0,0,4"/>
          <TextBlock Text="Start segment" Foreground="#666" FontSize="11"/>
          <TextBox x:Name="txtStartIndex" Text="7790" Margin="0,2,0,4"/>
          <TextBlock Text="Start sub (optional)" Foreground="#666" FontSize="11"/>
          <TextBox x:Name="txtStartSub" Margin="0,2,0,4"/>
          <TextBlock Text="Save interval (hours)" Foreground="#666" FontSize="11"/>
          <TextBox x:Name="txtSaveHours" Text="6" Margin="0,2,0,4"/>
          <TextBlock Text="Mode" Foreground="#666" FontSize="11"/>
          <ComboBox x:Name="cmbMode" SelectedIndex="0" Margin="0,2,0,4">
            <ComboBoxItem Content="uncompressed"/>
            <ComboBoxItem Content="compressed"/>
            <ComboBoxItem Content="both"/>
          </ComboBox>
          <CheckBox x:Name="chkAutoStart" Content="Register auto-start on logon" Margin="0,4,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
      <Button x:Name="btnStop" Content="Stop" Width="90" Height="34" Margin="0,0,8,0"
              Background="#DC2626" Foreground="White" FontWeight="SemiBold" BorderThickness="0"/>
      <Button x:Name="btnStart" Content="Start" Width="90" Height="34" Margin="0,0,8,0"
              Background="#2563EB" Foreground="White" FontWeight="SemiBold" BorderThickness="0"/>
      <TextBlock x:Name="lblStatus" Text="Idle" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#666"/>
      <TextBlock Text="Space = Start/Stop" VerticalAlignment="Center" Margin="16,0,0,0" Foreground="#999" FontSize="11"/>
    </StackPanel>

    <UniformGrid Grid.Row="2" Columns="6" Margin="0,0,0,10">
      <Border Background="White" CornerRadius="8" Padding="12" Margin="0,0,6,0">
        <StackPanel>
          <TextBlock Text="Generated" Foreground="#666" FontSize="11"/>
          <TextBlock x:Name="lblGenerated" Text="0" FontSize="22" FontWeight="Bold"/>
        </StackPanel>
      </Border>
      <Border Background="White" CornerRadius="8" Padding="12" Margin="0,0,6,0">
        <StackPanel>
          <TextBlock Text="Speed" Foreground="#666" FontSize="11"/>
          <TextBlock x:Name="lblSpeed" Text="—" FontSize="22" FontWeight="Bold" Foreground="#16A34A"/>
        </StackPanel>
      </Border>
      <Border Background="White" CornerRadius="8" Padding="12" Margin="0,0,6,0">
        <StackPanel>
          <TextBlock Text="Workers" Foreground="#666" FontSize="11"/>
          <TextBlock x:Name="lblWorkers" Text="1 CUDA" FontSize="22" FontWeight="Bold" Foreground="#0891B2"/>
        </StackPanel>
      </Border>
      <Border Background="White" CornerRadius="8" Padding="12" Margin="0,0,6,0">
        <StackPanel>
          <TextBlock Text="Match" Foreground="#666" FontSize="11"/>
          <TextBlock x:Name="lblMatch" Text="0" FontSize="22" FontWeight="Bold" Foreground="#CA8A04"/>
        </StackPanel>
      </Border>
      <Border Background="White" CornerRadius="8" Padding="12" Margin="0,0,6,0">
        <StackPanel>
          <TextBlock Text="ETA (segment)" Foreground="#666" FontSize="11"/>
          <TextBlock x:Name="lblEta" Text="—" FontSize="22" FontWeight="Bold" Foreground="#0891B2"/>
        </StackPanel>
      </Border>
      <Border Background="#EEF2FF" CornerRadius="8" Padding="12" BorderBrush="#2563EB" BorderThickness="1">
        <StackPanel>
          <TextBlock Text="Engine" Foreground="#666" FontSize="11"/>
          <TextBlock Text="KeyHunt CUDA" FontSize="16" FontWeight="SemiBold" Foreground="#2563EB"/>
          <TextBlock Text="GUI monitor + live key feed" FontSize="10" Foreground="#666"/>
        </StackPanel>
      </Border>
    </UniformGrid>

    <Border Grid.Row="3" Background="#DBEAFE" CornerRadius="8" Padding="12" Margin="0,0,0,6">
      <StackPanel>
        <TextBlock Text="Segment hunt — Puzzle #71" FontSize="16" FontWeight="Bold" Foreground="#1E3A8A"/>
        <TextBlock Text="Live table: sampled keys from KeyHunt [T:] progress (not every key — CUDA scans billions/s). Matches highlighted." TextWrapping="Wrap" Foreground="#1E40AF" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <Border Grid.Row="4" Background="#E5E7EB" CornerRadius="6" Padding="8,6" Margin="0,0,0,6">
      <TextBlock Text="Security tip: disconnect from the internet for maximum security when handling private keys." Foreground="#374151" FontSize="11"/>
    </Border>

    <DataGrid x:Name="dgLive" Grid.Row="5" AutoGenerateColumns="False" IsReadOnly="True"
              Background="White" Margin="0,0,0,10" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
              FontFamily="Consolas" FontSize="11" RowHeight="22">
      <DataGrid.Columns>
        <DataGridTextColumn Header="#" Binding="{Binding Num}" Width="45"/>
        <DataGridTextColumn Header="Private Key" Binding="{Binding PrivKey}" Width="2*"/>
        <DataGridTextColumn Header="Address" Binding="{Binding Address}" Width="*"/>
        <DataGridTextColumn Header="Balance" Binding="{Binding Balance}" Width="70"/>
        <DataGridTextColumn Header="Received" Binding="{Binding Received}" Width="70"/>
        <DataGridTextColumn Header="Match" Binding="{Binding Match}" Width="55"/>
      </DataGrid.Columns>
      <DataGrid.RowStyle>
        <Style TargetType="DataGridRow">
          <Style.Triggers>
            <DataTrigger Binding="{Binding IsMatch}" Value="True">
              <Setter Property="Foreground" Value="#CA8A04"/>
              <Setter Property="FontWeight" Value="Bold"/>
            </DataTrigger>
            <DataTrigger Binding="{Binding IsMatch}" Value="False">
              <Setter Property="Foreground" Value="#DC2626"/>
            </DataTrigger>
          </Style.Triggers>
        </Style>
      </DataGrid.RowStyle>
    </DataGrid>

    <Border Grid.Row="6" Background="White" CornerRadius="8" Padding="8">
      <DockPanel>
        <TextBlock DockPanel.Dock="Top" Text="runner.log (tail)" FontWeight="SemiBold" Margin="4,0,0,4"/>
        <TextBox x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                 VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Background="#FAFAFA"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtRangeStart = $window.FindName('txtRangeStart')
$txtRangeEnd = $window.FindName('txtRangeEnd')
$txtCurrentChunk = $window.FindName('txtCurrentChunk')
$lblSub = $window.FindName('lblSub')
$barSegment = $window.FindName('barSegment')
$lblSegmentPct = $window.FindName('lblSegmentPct')
$txtStartIndex = $window.FindName('txtStartIndex')
$txtStartSub = $window.FindName('txtStartSub')
$txtSaveHours = $window.FindName('txtSaveHours')
$cmbMode = $window.FindName('cmbMode')
$chkAutoStart = $window.FindName('chkAutoStart')
$btnStart = $window.FindName('btnStart')
$btnStop = $window.FindName('btnStop')
$lblStatus = $window.FindName('lblStatus')
$lblGenerated = $window.FindName('lblGenerated')
$lblSpeed = $window.FindName('lblSpeed')
$lblWorkers = $window.FindName('lblWorkers')
$lblMatch = $window.FindName('lblMatch')
$lblEta = $window.FindName('lblEta')
$dgLive = $window.FindName('dgLive')
$txtLog = $window.FindName('txtLog')

$btnStart.Add_Click({ Start-Scanner })
$btnStop.Add_Click({ Stop-Scanner })

$window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Space') {
        if (Get-ScannerRunning) { Stop-Scanner } else { Start-Scanner }
        $e.Handled = $true
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-Metrics })
$timer.Start()

$liveTimer = New-Object System.Windows.Threading.DispatcherTimer
$liveTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$liveTimer.Add_Tick({ Update-LiveTable })
$liveTimer.Start()

$window.Add_Closed({ Stop-Scanner; $timer.Stop(); $liveTimer.Stop() })

if ($txtLog -is [System.Windows.Controls.TextBox]) {
    # RichText not needed; plain append is fine
}

[void]$window.ShowDialog()
