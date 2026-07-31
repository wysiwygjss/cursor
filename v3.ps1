# KeyHunt Segment Scanner v3 - production wrapper
# Save as: C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1
#
# Run (pick ONE):
#   Double-click Run-V3.cmd
# ONE stable command (save + sub size = saveIntervalHours):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "...\Wrappers\v3.ps1" -startIndex 7790 -saveIntervalHours 6 -RegisterAutoStart
# Old 53687 tiny subs only: add -subCount 53687 (no autoSubSize)
# Do NOT use:  & v3.ps1   (execution policy blocks unless you Bypass the current session)

param(
    [int]$startIndex = -1,
    [int]$startSub   = -1,
    [int]$subCount   = 53687,
    [switch]$autoSubSize,
    [double]$hoursPerSub = 0,
    [double]$keysPerSecond = 4629710000,
    [ValidateSet("compressed", "uncompressed", "both")]
    [string]$mode = "uncompressed",
    [double]$saveIntervalHours = 2,
    [int]$keyHuntRetries = 5,
    [int]$keyHuntRetryDelaySeconds = 60,
    [int]$restartDelaySeconds = 30,
    [switch]$RegisterAutoStart,
    [switch]$UnregisterAutoStart,
    [string]$taskName = "KeyHunt Segment Scanner",
    [string]$targetFile = ""
)

# -saveIntervalHours 6 => ~6h subs + resume save every ~6h (unless -subCount 53687 for old tiny subs)
if ($hoursPerSub -le 0) { $hoursPerSub = $saveIntervalHours }
if ($PSBoundParameters.ContainsKey('saveIntervalHours') -and !$PSBoundParameters.ContainsKey('subCount')) {
    $autoSubSize = $true
}

$ErrorActionPreference = "Stop"

# ==================== PATHS (no spaces in folder names) ====================
$suiteRoot   = "C:\Users\Admin\Documents\KeyhuntSuite"
$wrapperDir  = Join-Path $suiteRoot "Wrappers"
$scriptSelf  = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $wrapperDir "v3.ps1" }
$segmentFile = Join-Path $suiteRoot "segment71_10000.txt"
$exe         = Join-Path $suiteRoot "Bin\KeyHunt-Cuda.exe"
$targetDir   = Join-Path $suiteRoot "Data\btc"
$defaultTarget = Join-Path $targetDir "hash160_sorted.bin"
$scanDir     = Join-Path $suiteRoot "Scanned_Segments"
$foundLog    = Join-Path $scanDir "Found_All.txt"
$scannedFile = Join-Path $scanDir "Scanned_Segments.txt"
$logFile     = Join-Path $wrapperDir "runner.log"
$mutexName   = "Global\KeyHuntSegmentScanner"

function Resolve-TargetFile {
    if ($targetFile -and (Test-Path $targetFile)) { return $targetFile }

    if (Test-Path $defaultTarget) { return $defaultTarget }

    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

    $found = @(Get-ChildItem -Path $suiteRoot -Recurse -Filter "hash160_sorted.bin" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'puzzle|_puzzle' })
    if ($found.Count -ge 1) {
        $pick = $found | Where-Object { $_.FullName -notmatch '\s' } | Select-Object -First 1
        if (!$pick) { $pick = $found[0] }
        if ($pick.FullName -ne $defaultTarget) {
            Copy-Item -Path $pick.FullName -Destination $defaultTarget -Force
            Write-Host "Copied target to: $defaultTarget" -ForegroundColor Cyan
        }
        return $defaultTarget
    }

    return $null
}

$targetFile = Resolve-TargetFile

New-Item -ItemType Directory -Force -Path $wrapperDir | Out-Null

# ==================== LOGGING ====================
function Log($m) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

function Now { Get-Date -Format "HH:mm:ss" }
function Info($m) { Write-Host "[$(Now)] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[$(Now)] $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "[$(Now)] $m" -ForegroundColor Green }

# ==================== HEX / RANGE ====================
function HexToBig($h) {
    $clean = ($h -replace '\s', '').Trim()
    if ($clean -match '^0x') { $clean = $clean.Substring(2) }
    [System.Numerics.BigInteger]::Parse("0" + $clean, [System.Globalization.NumberStyles]::HexNumber)
}

function BigToHex($n) { $n.ToString("X") }

function Format-ScanStamp { Get-Date -Format "MM/dd/yyyy HH:mm:ss" }

function Parse-SegmentRange($line) {
    $line = $line.Trim()
    if (!$line -or $line.StartsWith("#")) { return $null }

    if ($line -match ':') {
        $parts = $line.Split(':')
    }
    elseif ($line -match ',') {
        $parts = $line.Split(',')
        if ($parts.Count -ge 3) { $parts = @($parts[1], $parts[2]) }
    }
    else {
        Warn "Unrecognized segment line: $line"
        return $null
    }

    if ($parts.Count -lt 2) { return $null }
    return @{ Start = $parts[0].Trim(); End = $parts[1].Trim() }
}

function Get-SubRange(
    [System.Numerics.BigInteger]$segStart,
    [System.Numerics.BigInteger]$segEnd,
    [int]$subIndex,
    [int]$totalSubs
) {
    $total = $segEnd - $segStart + 1
    $subStart = $segStart + ($total * $subIndex / $totalSubs)
    $subEnd   = $segStart + ($total * ($subIndex + 1) / $totalSubs) - 1
    return @{ Start = $subStart; End = $subEnd }
}

function Get-ChunkKeyCount {
    $n = [int64]($keysPerSecond * $saveIntervalHours * 3600.0)
    if ($n -lt 1) { $n = 1 }
    return [System.Numerics.BigInteger]$n
}

function Get-SegmentSubCount(
    [System.Numerics.BigInteger]$segStart,
    [System.Numerics.BigInteger]$segEnd
) {
    if (!$autoSubSize) { return $subCount }

    $total = $segEnd - $segStart + 1
    $keysPerSub = [System.Numerics.BigInteger]([int64]($keysPerSecond * $hoursPerSub * 3600.0))
    if ($keysPerSub -le 0) { return $subCount }

    $n = ($total + $keysPerSub - 1) / $keysPerSub
    if ($n -lt 1) { return 1 }
    if ($n -gt 2147483647) { return 2147483647 }
    return [int]$n
}

function Get-RangeChunks(
    [System.Numerics.BigInteger]$start,
    [System.Numerics.BigInteger]$end,
    [System.Numerics.BigInteger]$chunkSize
) {
    $list = New-Object System.Collections.ArrayList
    $pos = $start
    while ($pos -le $end) {
        $chunkEnd = $pos + $chunkSize - 1
        if ($chunkEnd -gt $end) { $chunkEnd = $end }
        $list.Add(@{ Start = $pos; End = $chunkEnd }) | Out-Null
        $pos = $chunkEnd + 1
    }
    return $list
}

function Get-SubIndexForOffset(
    [System.Numerics.BigInteger]$segStart,
    [System.Numerics.BigInteger]$segEnd,
    [System.Numerics.BigInteger]$offset,
    [int]$totalSubs
) {
    if ($offset -le 0) { return 0 }
    $total = $segEnd - $segStart + 1
  if ($total -le 0) { return 0 }
    $idx = ($offset * $totalSubs) / $total
    return [int]$idx
}

# ==================== RESUME (max completed SUB - not last line) ====================
# 7790,776,71DB28E0E60D099E5C,71DB28E2E60D429E62,07/13/2026 05:58:33
function Parse-ResumeLine([string]$line) {
    if (!$line) { return $null }
    $line = $line.Trim()
    if ($line -match '^SEG') { return $null }

    if ($line -match '^(\d+),(\d+),([0-9A-Fa-f]+),([0-9A-Fa-f]+),(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})$') {
        $subIdx = [int]$Matches[2]
        if ($subIdx -ge 999999999) { return $null }
        return @{
            SegIdx    = [int]$Matches[1]
            SubIdx    = $subIdx
            StartHex  = $Matches[3]
            EndHex    = $Matches[4]
            Timestamp = $Matches[5]
        }
    }

    $parts = $line.Split(',')
    if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$' -and $parts[1] -match '^\d+$') {
        $subIdx = [int]$parts[1]
        if ($subIdx -ge 999999999) { return $null }
        return @{
            SegIdx    = [int]$parts[0]
            SubIdx    = $subIdx
            StartHex  = $null
            EndHex    = $null
            Timestamp = $parts[2].Trim()
        }
    }

    return $null
}

function Get-MaxResumeEntry([string]$resumeFile, [int]$segIdx) {
    if (!(Test-Path $resumeFile)) { return $null }

    $best = $null
    foreach ($line in @(Get-Content $resumeFile -ErrorAction SilentlyContinue)) {
        $parsed = Parse-ResumeLine $line
        if (!$parsed -or $parsed.SegIdx -ne $segIdx) { continue }

        if (!$best -or $parsed.SubIdx -gt $best.SubIdx) {
            $best = $parsed
        }
        elseif ($parsed.SubIdx -eq $best.SubIdx -and $parsed.Timestamp -gt $best.Timestamp) {
            $best = $parsed
        }
    }

    return $best
}

function Get-LastResumeEntry([string]$resumeFile, [int]$segIdx) {
    if (!(Test-Path $resumeFile)) { return $null }

    $lines = @(Get-Content $resumeFile -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $parsed = Parse-ResumeLine $lines[$i]
        if ($parsed -and $parsed.SegIdx -eq $segIdx) { return $parsed }
    }

    return $null
}

function Get-ResumeState(
    [int]$segIdx,
    [int]$segSubCount,
    [System.Numerics.BigInteger]$segStart,
    [System.Numerics.BigInteger]$segEnd
) {
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    $lastSubIdx = $segSubCount - 1
    $state = @{
        Complete = $false
        NextSub  = 0
        LastSub  = -1
        Partial  = $false
        File     = $resumeFile
        EndHex   = $null
    }

    $maxEntry = Get-MaxResumeEntry $resumeFile $segIdx
    if (!$maxEntry) { return $state }

    $lastEntry = Get-LastResumeEntry $resumeFile $segIdx
    if ($lastEntry -and $lastEntry.SubIdx -lt $maxEntry.SubIdx) {
        Warn "SEG ${segIdx}: last line SUB $($lastEntry.SubIdx) < highest SUB $($maxEntry.SubIdx) - using highest"
    }

    $state.LastSub = $maxEntry.SubIdx
    $state.EndHex  = $maxEntry.EndHex

    $subComplete = $false
    if ($maxEntry.EndHex) {
        $subRange = Get-SubRange $segStart $segEnd $maxEntry.SubIdx $segSubCount
        $expectedEnd = (BigToHex $subRange.End).ToUpper()
        if ($maxEntry.EndHex.ToUpper() -eq $expectedEnd) {
            $subComplete = $true
            $state.NextSub = $maxEntry.SubIdx + 1
        }
        else {
            $state.Partial = $true
            $state.NextSub = $maxEntry.SubIdx
        }
    }
    else {
        $state.NextSub = $maxEntry.SubIdx + 1
        $subComplete = $true
    }

    if ($autoSubSize -and $maxEntry.EndHex) {
        $continueKey = HexToBig $maxEntry.EndHex + 1
        if ($continueKey -le $segEnd) {
            $offset = $continueKey - $segStart
            $mappedSub = Get-SubIndexForOffset $segStart $segEnd $offset $segSubCount
            $state.NextSub = $mappedSub
            $state.Partial = $true
            $state.LastSub = $mappedSub
        }
    }

    if ($maxEntry.SubIdx -eq $lastSubIdx -and $subComplete) {
        $state.Complete = $true
        $state.NextSub  = $segSubCount
    }

    return $state
}

function Find-NextOpenSegment([int]$fromIdx, [int]$toIdx, $segments) {
    for ($i = $fromIdx; $i -lt $toIdx; $i++) {
        $range = Parse-SegmentRange $segments[$i]
        if (!$range) { continue }
        $st = HexToBig $range.Start
        $en = HexToBig $range.End
        $ssc = Get-SegmentSubCount $st $en
        $state = Get-ResumeState $i $ssc $st $en
        if (!$state.Complete) {
            return @{ Found = $true; Index = $i; NextSub = $state.NextSub }
        }
    }
    return @{ Found = $false }
}

function Save-Resume(
    [string]$resumeFile,
    [int]$segIdx,
    [int]$sub,
    [string]$startHex,
    [string]$endHex
) {
    $line = "$segIdx,$sub,$startHex,$endHex,$(Format-ScanStamp)"

    $maxEntry = Get-MaxResumeEntry $resumeFile $segIdx
    if ($maxEntry -and $sub -lt $maxEntry.SubIdx) {
        Warn "Skip resume write SUB $sub (highest completed SUB $($maxEntry.SubIdx))"
    }
    elseif ($maxEntry -and $sub -eq $maxEntry.SubIdx -and $maxEntry.EndHex -eq $endHex.ToUpper()) {
        Warn "Skip duplicate resume line for SUB $sub"
    }
    else {
        Add-Content -Path $resumeFile -Value $line
    }

    Add-Content -Path $scannedFile -Value $line
}

# ==================== KEYHUNT ====================
function Invoke-KeyHunt([string]$rangeStr, [string]$outFile, [string]$modeFlag) {
    $argList = @(
        "-t", "0",
        "-g",
        "-m", "addresses",
        "--coin", "BTC",
        "--range", $rangeStr,
        "-i", $targetFile,
        "-o", $outFile
    )
    if ($modeFlag) { $argList += $modeFlag }

    $lastExit = 1
    for ($attempt = 1; $attempt -le $keyHuntRetries; $attempt++) {
        # Use & not Start-Process - paths with spaces (e.g. "Original BTC Core") must stay one argument
        $cmdPreview = "$exe " + ($argList | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '
        Info "KeyHunt: $cmdPreview"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Start-Process -Wait blocks until KeyHunt exits; ArgumentList keeps paths as single args
            $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru
            $lastExit = if ($proc) { $proc.ExitCode } else { 1 }
        }
        finally {
            $ErrorActionPreference = $oldEap
        }
        $sw.Stop()
        Info ("KeyHunt finished in {0:N1}s exit {1}" -f $sw.Elapsed.TotalSeconds, $lastExit)
        if ($lastExit -eq 0) { return 0 }

        Warn "KeyHunt exit $lastExit (attempt $attempt/$keyHuntRetries)"
        if ($attempt -lt $keyHuntRetries) {
            Start-Sleep -Seconds $keyHuntRetryDelaySeconds
        }
    }

    return $lastExit
}

# ==================== AUTO-START (reboot / crash) ====================
function Invoke-SchTasks([string[]]$schArgs) {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & schtasks.exe @schArgs 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    return $code
}

function Register-AutoStartTask {
    if (!(Test-Path $scriptSelf)) {
        Write-Host "Script not found: $scriptSelf" -ForegroundColor Red
        return $false
    }

    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptSelf`" -startIndex $startIndex -saveIntervalHours $saveIntervalHours -mode $mode"
    if ($startSub -ge 0) { $argString += " -startSub $startSub" }
    if ($targetFile) { $argString += " -targetFile `"$targetFile`"" }
    if ($autoSubSize) { $argString += " -autoSubSize -hoursPerSub $hoursPerSub -keysPerSecond $keysPerSecond" }
    elseif ($subCount -ne 53687) { $argString += " -subCount $subCount" }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $argString `
        -WorkingDirectory $wrapperDir

    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1)

  # Limited = no Administrator required (Highest needs elevated PowerShell)
    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    try {
        $triggerBoot = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger @($triggerBoot, $triggerLogon) `
            -Settings $settings `
            -Principal $principal `
            -Description "KeyHunt v3 - auto-start after reboot, resume highest SUB per segment"
    }
    catch {
        try {
            Warn "Startup trigger needs Admin; registering logon-only task instead."
            Register-ScheduledTask `
                -TaskName $taskName `
                -Action $action `
                -Trigger $triggerLogon `
                -Settings $settings `
                -Principal $principal `
                -Description "KeyHunt v3 - auto-start at logon, resume highest SUB per segment"
        }
        catch {
            Warn "Register-ScheduledTask failed; trying schtasks..."
            if (Register-AutoStartViaSchTasks $argString) { return $true }
            Write-Host "Could not register scheduled task: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Scan will still run now. For auto-start after reboot:" -ForegroundColor Yellow
            Write-Host "  1) Right-click PowerShell -> Run as administrator, then run with -RegisterAutoStart" -ForegroundColor Yellow
            Write-Host "  2) Or run without -RegisterAutoStart and start manually after reboot" -ForegroundColor Yellow
            return $false
        }
    }

    Write-Host "Registered '$taskName' -> v3.ps1" -ForegroundColor Green
    Write-Host "  startIndex=$startIndex saveIntervalHours=$saveIntervalHours mode=$mode"
    return $true
}

function Register-AutoStartViaSchTasks([string]$argString) {
    $tr = "powershell.exe $argString"
    Invoke-SchTasks @('/Delete', '/TN', $taskName, '/F') | Out-Null
    $code = Invoke-SchTasks @('/Create', '/TN', $taskName, '/TR', $tr, '/SC', 'ONLOGON', '/RL', 'LIMITED', '/F')
    if ($code -eq 0) {
        Write-Host "Registered '$taskName' via schtasks (starts at logon)." -ForegroundColor Green
        return $true
    }
    return $false
}

function Unregister-AutoStartTask {
    Invoke-SchTasks @('/Delete', '/TN', $taskName, '/F') | Out-Null
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed '$taskName'." -ForegroundColor Green
    }
    else {
        Write-Host "Task '$taskName' not found." -ForegroundColor Yellow
    }
}

if ($UnregisterAutoStart) {
    Unregister-AutoStartTask
    exit 0
}

if ($RegisterAutoStart) {
    try {
        $registered = Register-AutoStartTask
        if (!$registered) {
            Warn "Auto-start not registered; continuing with scan."
        }
    }
    catch {
        Warn "Auto-start registration failed: $($_.Exception.Message); continuing with scan."
    }
}

# ==================== SCAN ====================
function Run-Scan([bool]$explicitStartSub) {
    New-Item -ItemType Directory -Force -Path $scanDir | Out-Null

    $floorIndex = if ($startIndex -ge 0) { $startIndex } else { 0 }

    if (!(Test-Path $segmentFile)) {
        Write-Host "Segment file missing: $segmentFile" -ForegroundColor Red
        return 1
    }
    if (!(Test-Path $exe)) {
        Write-Host "KeyHunt not found: $exe" -ForegroundColor Red
        return 1
    }
    if (!$targetFile) {
        Write-Host "Target file not found: $defaultTarget" -ForegroundColor Red
        Write-Host "Copy hash160_sorted.bin to Data\btc\ or pass -targetFile" -ForegroundColor Yellow
        return 1
    }
    Info "Target: $targetFile"

    $modeFlag = switch ($mode) {
        "uncompressed" { "-u" }
        "both"         { "-b" }
        default        { $null }
    }

    $segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") })
    Info ("v3 | segments: {0} | floor: {1} | save+sub every {2}h | autoSubSize={3}" -f $segments.Count, $floorIndex, $saveIntervalHours, $autoSubSize)
    Info "Resume: highest completed SUB per segment (stray low lines ignored)"

    $seg = $startIndex
    $sub = $startSub

    if ($seg -ge 0) {
        if (!$explicitStartSub) {
            $initRange = Parse-SegmentRange $segments[$seg]
            if ($initRange) {
                $ist = HexToBig $initRange.Start
                $ien = HexToBig $initRange.End
                $iss = Get-SegmentSubCount $ist $ien
                $state = Get-ResumeState $seg $iss $ist $ien
            }
            else {
                $state = @{ Complete = $false; NextSub = 0; LastSub = -1; Partial = $false }
            }
            if ($state.Complete) {
                Warn "SEG $seg complete - advancing"
                $next = Find-NextOpenSegment ($seg + 1) $segments.Count $segments
                if ($next.Found) {
                    $seg = $next.Index
                    $sub = $next.NextSub
                    Info "Continue SEG $seg SUB $sub"
                }
                else {
                    Ok "All segments from $floorIndex to $($segments.Count - 1) complete."
                    return 0
                }
            }
            else {
                $sub = $state.NextSub
                if ($state.LastSub -ge 0) {
                    Info ("Resume SEG {0} highest SUB {1} -> start SUB {2}" -f $seg, $state.LastSub, $sub)
                }
                else {
                    Info "SEG $seg from SUB 0"
                }
            }
        }
        else {
            Info "Explicit SEG $seg SUB $sub"
        }
    }
    else {
        $next = Find-NextOpenSegment $floorIndex $segments.Count $segments
        if ($next.Found) {
            $seg = $next.Index
            if (!$explicitStartSub) { $sub = $next.NextSub }
            Info "Auto-resume SEG $seg SUB $sub"
        }
        else {
            Ok "All segments complete."
            return 0
        }
    }

    if ($seg -lt $floorIndex) { $seg = $floorIndex; $sub = 0 }
    if ($seg -ge $segments.Count) {
        Write-Host "Invalid segment index $seg" -ForegroundColor Red
        return 1
    }
    if ($sub -lt 0) { $sub = 0 }

    $checkpointTimer = Get-Date
    $entrySeg = $seg
    $entrySub = if ($explicitStartSub) { $sub } else { -1 }

    for ($segIdx = $seg; $segIdx -lt $segments.Count; $segIdx++) {
        if ($segIdx -lt $floorIndex) { continue }

        $range = Parse-SegmentRange $segments[$segIdx]
        if (!$range) {
            Warn "Invalid segment line at index $segIdx"
            continue
        }

        $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
        $segStartBig = HexToBig $range.Start
        $segEndBig   = HexToBig $range.End

        if ($segEndBig -lt $segStartBig) {
            Warn "Invalid range SEG $segIdx"
            continue
        }

        $segSubCount = Get-SegmentSubCount $segStartBig $segEndBig
        $chunkKeys = Get-ChunkKeyCount

        if ($autoSubSize) {
            Info ("SEG ${segIdx}: $segSubCount subs (~${hoursPerSub}h each at $keysPerSecond keys/s)")
        }

        $state = Get-ResumeState $segIdx $segSubCount $segStartBig $segEndBig
        if ($state.Complete) {
            Info "SEG $segIdx complete - next segment"
            continue
        }

        if ($segIdx -eq $entrySeg -and $entrySub -ge 0) {
            $subStart = $entrySub
            $entrySub = -1
        }
        else {
            $subStart = $state.NextSub
        }

        if ($subStart -lt 0) { $subStart = 0 }
        if ($subStart -ge $segSubCount) { continue }

        Info ("SEG {0} {1}:{2} | SUB {3}-{4}" -f $segIdx, $range.Start, $range.End, $subStart, ($segSubCount - 1))

        for ($s = $subStart; $s -lt $segSubCount; $s++) {
            $subRange = Get-SubRange $segStartBig $segEndBig $s $segSubCount
            $runStart = $subRange.Start
            $runEnd = $subRange.End

            if ($s -eq $state.NextSub -and $state.EndHex -and $state.Partial) {
                $resumeEnd = HexToBig $state.EndHex
                $runStart = $resumeEnd + 1
                if ($runStart -gt $runEnd) { continue }
            }

            $chunks = @(Get-RangeChunks $runStart $runEnd $chunkKeys)
            foreach ($chunk in $chunks) {
                $startHex = BigToHex $chunk.Start
                $endHex   = BigToHex $chunk.End
                $rangeStr = "${startHex}:${endHex}"
                $outFile  = Join-Path $scanDir "seg${segIdx}_sub${s}_found.txt"

                Info ("SEG $segIdx SUB $s/$($segSubCount - 1) chunk $rangeStr")

                $exitCode = Invoke-KeyHunt $rangeStr $outFile $modeFlag
                if ($exitCode -ne 0) {
                    Warn "KeyHunt failed SEG $segIdx SUB $s"
                    return $exitCode
                }

                if (Test-Path $outFile) {
                    $hits = Get-Content $outFile -ErrorAction SilentlyContinue
                    if ($hits) {
                        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        foreach ($hit in $hits) {
                            if ($hit.Trim()) {
                                $foundMsg = "[{0}] SEG {1} SUB {2} | {3}" -f $stamp, $segIdx, $s, $hit
                                Add-Content -Path $foundLog -Value $foundMsg
                                Ok "FOUND: $hit"
                            }
                        }
                    }
                }

                Save-Resume $resumeFile $segIdx $s ($startHex.ToUpper()) ($endHex.ToUpper())
                Ok ("Saved SEG $segIdx SUB $s through $endHex")

                if (((Get-Date) - $checkpointTimer).TotalHours -ge $saveIntervalHours) {
                    Ok "Checkpoint SEG $segIdx SUB $s"
                    $checkpointTimer = Get-Date
                }
            }
        }

        Ok "SEG $segIdx complete - next segment"
    }

    Ok "Scan finished."
    return 0
}

# ==================== RUNNER ====================
$explicitStartSub = $PSBoundParameters.ContainsKey("startSub") -and $startSub -ge 0

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (!$mutex.WaitOne(0)) {
    Log "v3 already running."
    exit 0
}

Log ("v3 started | startIndex={0} | saveInterval={1}h | mode={2}" -f $startIndex, $saveIntervalHours, $mode)

$useExplicitSub = $explicitStartSub
while ($true) {
    try {
        $code = Run-Scan -explicitStartSub $useExplicitSub
        $useExplicitSub = $false
        if ($code -eq 0) {
            Log "v3 finished normally."
            break
        }
        Log "v3 exit $code - retry in ${restartDelaySeconds}s (resume from highest SUB)"
    }
    catch {
        Log "v3 error: $($_.Exception.Message) - retry in ${restartDelaySeconds}s (resume from highest SUB)"
        $useExplicitSub = $false
    }
    Start-Sleep -Seconds $restartDelaySeconds
}

$mutex.ReleaseMutex()
Log "v3 stopped."
