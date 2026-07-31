param(
    [int]$startIndex = -1,
    [int]$startSub   = -1,
    [int]$subCount   = 53687,
    [ValidateSet("compressed", "uncompressed", "both")]
    [string]$mode = "uncompressed",
    [double]$saveIntervalHours = 2,
    [int]$keyHuntRetries = 5,
    [int]$keyHuntRetryDelaySeconds = 60,
    [int]$restartDelaySeconds = 30,
    [switch]$RegisterAutoStart,
    [switch]$UnregisterAutoStart,
    [string]$taskName = "KeyHunt Segment Scanner"
)

$ErrorActionPreference = "Stop"

# ==================== PATHS ====================
$wrapperDir  = "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers"
$segmentFile = "C:\Users\Admin\Documents\KeyhuntSuite\segment71_10000.txt"
$exe         = "C:\Users\Admin\Documents\KeyhuntSuite\Bin\KeyHunt-Cuda.exe"
$targetFile  = "C:\Users\Admin\Documents\KeyhuntSuite\bitcoincore_utxo\hash160_sorted.bin"
$scanDir     = "C:\Users\Admin\Documents\KeyhuntSuite\Scanned_Segments"
$foundLog    = Join-Path $scanDir "Found_All.txt"
$scannedFile = Join-Path $scanDir "Scanned_Segments.txt"
$logFile     = Join-Path $wrapperDir "runner.log"
$mutexName   = "Global\KeyHuntSegmentScanner"

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

# ==================== RESUME ====================
# Line format: 7790,776,71DB28E0E60D099E5C,71DB28E2E60D429E62,07/13/2026 05:58:33
function Parse-ResumeLine([string]$line) {
    if (!$line) { return $null }
    $line = $line.Trim()
    if ($line -match '^SEG') { return $null }

    if ($line -match '^(\d+),(\d+),([0-9A-Fa-f]+),([0-9A-Fa-f]+),(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})$') {
        $subIdx = [int]$Matches[2]
        if ($subIdx -ge $subCount) { return $null }
        return @{
            SegIdx   = [int]$Matches[1]
            SubIdx   = $subIdx
            StartHex = $Matches[3]
            EndHex   = $Matches[4]
        }
    }

    $parts = $line.Split(',')
    if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$' -and $parts[1] -match '^\d+$') {
        $subIdx = [int]$parts[1]
        if ($subIdx -ge $subCount) { return $null }
        return @{
            SegIdx   = [int]$parts[0]
            SubIdx   = $subIdx
            StartHex = $null
            EndHex   = $null
        }
    }

    return $null
}

function Get-LastResume([string]$resumeFile, [int]$segIdx) {
    if (!(Test-Path $resumeFile)) { return $null }
    $lines = @(Get-Content $resumeFile -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $parsed = Parse-ResumeLine $lines[$i]
        if ($parsed -and $parsed.SegIdx -eq $segIdx) { return $parsed }
    }
    return $null
}

function Get-ResumeState([int]$segIdx) {
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    $lastSubIdx = $subCount - 1
    $state = @{
        Complete = $false
        NextSub  = 0
        LastSub  = -1
        File     = $resumeFile
    }

    $parsed = Get-LastResume $resumeFile $segIdx
    if (!$parsed) { return $state }

    $state.LastSub = $parsed.SubIdx
    $state.NextSub = $parsed.SubIdx + 1

    if ($parsed.SubIdx -eq $lastSubIdx) {
        $state.Complete = $true
        $state.NextSub  = $subCount
    }

    return $state
}

function Find-NextOpenSegment([int]$fromIdx, [int]$toIdx) {
    for ($i = $fromIdx; $i -lt $toIdx; $i++) {
        $state = Get-ResumeState $i
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
    Add-Content -Path $resumeFile -Value $line
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

    for ($attempt = 1; $attempt -le $keyHuntRetries; $attempt++) {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -eq 0) { return 0 }

        Warn "KeyHunt exit $($proc.ExitCode) (attempt $attempt/$keyHuntRetries)"
        if ($attempt -lt $keyHuntRetries) {
            Start-Sleep -Seconds $keyHuntRetryDelaySeconds
        }
    }

    return $proc.ExitCode
}

# ==================== AUTO-START (reboot / crash) ====================
function Register-AutoStartTask {
    $scriptPath = $PSCommandPath
    if (!$scriptPath) {
        $scriptPath = Join-Path $wrapperDir "Run-KeyHunt-Service.ps1"
    }

    if (!(Test-Path $scriptPath)) {
        Write-Host "Script not found: $scriptPath" -ForegroundColor Red
        return $false
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", "`"$scriptPath`"",
        "-startIndex", $startIndex,
        "-saveIntervalHours", $saveIntervalHours,
        "-mode", $mode
    )
    if ($startSub -ge 0) { $args += "-startSub"; $args += $startSub }

    $argString = ($args -join ' ')

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $argString `
        -WorkingDirectory $wrapperDir

    $triggerBoot  = New-ScheduledTaskTrigger -AtStartup
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Highest

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($triggerBoot, $triggerLogon) `
        -Settings $settings `
        -Principal $principal `
        -Description "KeyHunt segment scanner — auto-start after reboot, resume from Scanned_Segments"

    Write-Host "Registered '$taskName' for auto-start after reboot." -ForegroundColor Green
    Write-Host "  startIndex=$startIndex saveIntervalHours=$saveIntervalHours mode=$mode"
    return $true
}

function Unregister-AutoStartTask {
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
    if (Register-AutoStartTask) { exit 0 }
    exit 1
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
    if (!(Test-Path $targetFile)) {
        Write-Host "Target file missing: $targetFile" -ForegroundColor Red
        return 1
    }

    $modeFlag = switch ($mode) {
        "uncompressed" { "-u" }
        "both"         { "-b" }
        default        { $null }
    }

    $segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") })
    Info "Segments: $($segments.Count) | floor: $floorIndex | checkpoint: ${saveIntervalHours}h"

    $seg = $startIndex
    $sub = $startSub

    if ($seg -ge 0) {
        if (!$explicitStartSub) {
            $state = Get-ResumeState $seg
            if ($state.Complete) {
                Warn "SEG $seg complete — advancing"
                $next = Find-NextOpenSegment ($seg + 1) $segments.Count
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
                    Info "Resume SEG $seg after SUB $state.LastSub → SUB $sub"
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
        $next = Find-NextOpenSegment $floorIndex $segments.Count
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

        $state = Get-ResumeState $segIdx
        if ($state.Complete) {
            Info "SEG $segIdx complete — next segment"
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
        if ($subStart -ge $subCount) { continue }

        Info "SEG $segIdx $($range.Start):$($range.End) | SUB $subStart–$($subCount - 1)"

        for ($s = $subStart; $s -lt $subCount; $s++) {
            $subRange = Get-SubRange $segStartBig $segEndBig $s $subCount
            $startHex = BigToHex $subRange.Start
            $endHex   = BigToHex $subRange.End
            $rangeStr = "${startHex}:${endHex}"
            $outFile  = Join-Path $scanDir "seg${segIdx}_sub${s}_found.txt"

            Info "SEG $segIdx SUB $s/$($subCount - 1) $rangeStr"

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
                            Add-Content -Path $foundLog -Value "[$stamp] SEG $segIdx SUB $s | $hit"
                            Ok "FOUND: $hit"
                        }
                    }
                }
            }

            Save-Resume $resumeFile $segIdx $s $startHex $endHex

            if (((Get-Date) - $checkpointTimer).TotalHours -ge $saveIntervalHours) {
                Ok "Checkpoint SEG $segIdx SUB $s"
                $checkpointTimer = Get-Date
            }
        }

        Ok "SEG $segIdx complete — next segment"
    }

    Ok "Scan finished."
    return 0
}

# ==================== RUNNER ====================
$explicitStartSub = $PSBoundParameters.ContainsKey('startSub') -and $startSub -ge 0

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (!$mutex.WaitOne(0)) {
    Log "Already running."
    exit 0
}

Log "Runner started | startIndex=$startIndex | saveInterval=${saveIntervalHours}h | mode=$mode"

while ($true) {
    try {
        $code = Run-Scan -explicitStartSub $explicitStartSub
        if ($code -eq 0) {
            Log "Runner finished normally."
            break
        }
        Log "Scan exit $code — retry in ${restartDelaySeconds}s"
    }
    catch {
        Log "Error: $($_.Exception.Message) — retry in ${restartDelaySeconds}s"
    }
    Start-Sleep -Seconds $restartDelaySeconds
}

$mutex.ReleaseMutex()
Log "Runner stopped."
