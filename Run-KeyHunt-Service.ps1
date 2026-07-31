# One file — run:
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\Run-KeyHunt-Service.ps1" -startIndex 7790 -saveIntervalHours 6

param(
    [int]$startIndex = 7790,
    [int]$startSub   = -1,
    [int]$subCount   = 53687,
    [ValidateSet("compressed", "uncompressed", "both")]
    [string]$mode = "uncompressed",
    [double]$saveIntervalHours = 6,
    [int]$keyHuntRetries = 5,
    [int]$keyHuntRetryDelaySeconds = 60,
    [int]$restartDelaySeconds = 30
)

$wrapperDir  = "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers"
$segmentFile = "C:\Users\Admin\Documents\KeyhuntSuite\segment71_10000.txt"
$exe         = "C:\Users\Admin\Documents\KeyhuntSuite\Bin\KeyHunt-Cuda.exe"
$targetFile  = "C:\Users\Admin\Documents\KeyhuntSuite\bitcoincore_utxo\hash160_sorted.bin"
$scanDir     = "C:\Users\Admin\Documents\KeyhuntSuite\Scanned_Segments"
$foundLog    = Join-Path $scanDir "Found_All.txt"
$scannedFile = Join-Path $scanDir "Scanned_Segments.txt"
$logFile     = Join-Path $wrapperDir "runner.log"
$mutexName   = "Global\KeyHuntSegmentScanner"

function Log($m) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

function Now { Get-Date -Format "HH:mm:ss" }
function Info($m) { Write-Host "[$(Now)] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[$(Now)] $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "[$(Now)] $m" -ForegroundColor Green }

function HexToBig($h) {
    $clean = ($h -replace '\s', '').Trim()
    if ($clean -match '^0x') { $clean = $clean.Substring(2) }
    [System.Numerics.BigInteger]::Parse("0" + $clean, [System.Globalization.NumberStyles]::HexNumber)
}

function Format-ScanStamp { Get-Date -Format "MM/dd/yyyy HH:mm:ss" }
function BigToHex($n) { $n.ToString("X") }
function Format-ScanLine([int]$segIdx, [int]$sub, [string]$startHex, [string]$endHex) {
    "$segIdx,$sub,$startHex,$endHex,$(Format-ScanStamp)"
}

function Parse-ScanLine([string]$line) {
    if (!$line) { return $null }
    $line = $line.Trim()
    if ($line -match '^SEG') { return $null }

    if ($line -match '^(\d+),(\d+),([0-9A-Fa-f]+),([0-9A-Fa-f]+),(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})$') {
        $subIdx = [int]$Matches[2]
        if ($subIdx -ge $subCount) {
            Warn "Ignoring invalid resume line (sub $subIdx >= subCount $subCount): $line"
            return $null
        }
        return @{
            SegIdx    = [int]$Matches[1]
            SubIdx    = $subIdx
            StartHex  = $Matches[3]
            EndHex    = $Matches[4]
            Timestamp = $Matches[5].Trim()
        }
    }

    $parts = $line.Split(',')
    if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$' -and $parts[1] -match '^\d+$') {
        $subIdx = [int]$parts[1]
        if ($subIdx -ge $subCount) { return $null }
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

function Get-LastScanLine([string]$filePath, [int]$expectedSegIdx) {
    if (!(Test-Path $filePath)) { return $null }
    $lines = @(Get-Content $filePath -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $parsed = Parse-ScanLine $lines[$i]
        if ($parsed -and $parsed.SegIdx -eq $expectedSegIdx) { return $parsed }
    }
    return $null
}

function Parse-SegmentRange($line) {
    $line = $line.Trim()
    if (!$line -or $line.StartsWith("#")) { return $null }

    if ($line -match ':') { $parts = $line.Split(':') }
    elseif ($line -match ',') {
        $parts = $line.Split(',')
        if ($parts.Count -ge 3) { $parts = @($parts[1], $parts[2]) }
    }
    else {
        Warn "Unrecognized segment line format: $line"
        return $null
    }

    if ($parts.Count -lt 2) {
        Warn "Segment line needs start and end: $line"
        return $null
    }

    return @{ Start = $parts[0].Trim(); End = $parts[1].Trim() }
}

function Get-SubRange([System.Numerics.BigInteger]$segStart, [System.Numerics.BigInteger]$segEnd, [int]$subIndex, [int]$totalSubs) {
    $total = $segEnd - $segStart + 1
    $subStart = $segStart + ($total * $subIndex / $totalSubs)
    $subEnd   = $segStart + ($total * ($subIndex + 1) / $totalSubs) - 1
    return @{ Start = $subStart; End = $subEnd }
}

function Get-ResumeState([int]$segIdx) {
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    $lastSubIdx = $subCount - 1
    $state = @{ Complete = $false; NextSub = 0; LastSub = -1; File = $resumeFile }

    $parsed = Get-LastScanLine $resumeFile $segIdx
    if (!$parsed) { return $state }

    $state.LastSub = $parsed.SubIdx
    $state.NextSub = $parsed.SubIdx + 1
    if ($parsed.SubIdx -eq $lastSubIdx) {
        $state.Complete = $true
        $state.NextSub  = $subCount
    }
    return $state
}

function Find-NextIncompleteSegment([int]$fromIndex, [int]$toIndex) {
    for ($i = $fromIndex; $i -lt $toIndex; $i++) {
        $state = Get-ResumeState $i
        if (!$state.Complete) {
            return @{ Found = $true; Index = $i; NextSub = $state.NextSub }
        }
    }
    return @{ Found = $false; Index = -1; NextSub = 0 }
}

function Write-ScannedRecord([string]$resumeFile, [int]$segIdx, [int]$sub, [string]$startHex, [string]$endHex) {
    $line = Format-ScanLine $segIdx $sub $startHex $endHex
    Add-Content -Path $resumeFile -Value $line
    Add-Content -Path $scannedFile -Value $line
}

function Invoke-KeyHuntRun([string]$rangeStr, [string]$outFile, [string]$modeFlag) {
    $argList = @(
        "-t", "0", "-g", "-m", "addresses", "--coin", "BTC",
        "--range", $rangeStr, "-i", $targetFile, "-o", $outFile
    )
    if ($modeFlag) { $argList += $modeFlag }

    for ($attempt = 1; $attempt -le $keyHuntRetries; $attempt++) {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -eq 0) { return 0 }
        Warn "KeyHunt exit code $($proc.ExitCode) (attempt $attempt/$keyHuntRetries)"
        if ($attempt -lt $keyHuntRetries) {
            Info "Retrying in $keyHuntRetryDelaySeconds second(s)..."
            Start-Sleep -Seconds $keyHuntRetryDelaySeconds
        }
    }
    return $proc.ExitCode
}

function Start-SegmentScan([bool]$explicitStartSub) {
    New-Item -ItemType Directory -Force -Path $scanDir | Out-Null

    $floorIndex = if ($startIndex -ge 0) { $startIndex } else { 0 }

    if (!(Test-Path $segmentFile)) { Write-Host "Segment file missing: $segmentFile" -ForegroundColor Red; return 1 }
    if (!(Test-Path $exe))         { Write-Host "KeyHunt not found: $exe" -ForegroundColor Red; return 1 }
    if (!(Test-Path $targetFile))  { Write-Host "Target file missing: $targetFile" -ForegroundColor Red; return 1 }

    $modeFlag = switch ($mode) {
        "uncompressed" { "-u" }
        "both"         { "-b" }
        default        { $null }
    }

    $segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") })
    Info "Loaded $($segments.Count) segments"
    Info "Save interval: $saveIntervalHours hour(s) | floor SEG $floorIndex"

    $scanStartIndex = $startIndex
    $scanStartSub   = $startSub
    $initialSegIdx    = -1
    $initialSubOverride = -1

    if ($scanStartIndex -ge 0) {
        $initialSegIdx = $scanStartIndex

        if ($explicitStartSub) {
            $initialSubOverride = $scanStartSub
            Info "Explicit start: SEG $scanStartIndex SUB $scanStartSub"
        }
        else {
            $state = Get-ResumeState $scanStartIndex
            if ($state.LastSub -ge 0) {
                Info "Resume: SEG $scanStartIndex last SUB $state.LastSub -> next SUB $state.NextSub"
            }
            else {
                Info "No resume for SEG $scanStartIndex -> SUB 0"
            }

            if ($state.Complete) {
                Warn "SEG $scanStartIndex complete -> next segment"
                $next = Find-NextIncompleteSegment ($scanStartIndex + 1) $segments.Count
                if ($next.Found) {
                    $scanStartIndex = $next.Index
                    $initialSegIdx = $scanStartIndex
                    $scanStartSub = $next.NextSub
                    Info "Continuing at SEG $scanStartIndex SUB $scanStartSub"
                }
                else {
                    Ok "All segments from floor $floorIndex through $($segments.Count - 1) are complete."
                    return 0
                }
            }
            else {
                $scanStartSub = $state.NextSub
                Info "Resuming SEG $scanStartIndex from SUB $scanStartSub"
            }
        }
    }
    else {
        $next = Find-NextIncompleteSegment $floorIndex $segments.Count
        if ($next.Found) {
            $scanStartIndex = $next.Index
            $initialSegIdx = $scanStartIndex
            if (!$explicitStartSub) { $scanStartSub = $next.NextSub }
            Info "Auto-resume: SEG $scanStartIndex from SUB $scanStartSub"
        }
        else {
            Ok "All segments from floor $floorIndex onward are complete."
            return 0
        }
    }

    if ($scanStartIndex -lt $floorIndex) {
        $scanStartIndex = $floorIndex
        $scanStartSub = 0
    }

    if ($scanStartIndex -ge $segments.Count) {
        Write-Host "Invalid startIndex $scanStartIndex" -ForegroundColor Red
        return 1
    }

    if ($scanStartSub -lt 0) { $scanStartSub = 0 }

    $checkpointTimer = Get-Date

    for ($segIdx = $scanStartIndex; $segIdx -lt $segments.Count; $segIdx++) {
        if ($segIdx -lt $floorIndex) { continue }

        $range = Parse-SegmentRange $segments[$segIdx]
        if (!$range) {
            Warn "Skipping invalid segment line at index $segIdx"
            continue
        }

        $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
        $segStartBig = HexToBig $range.Start
        $segEndBig   = HexToBig $range.End

        if ($segEndBig -lt $segStartBig) {
            Warn "SEG $segIdx invalid range $($range.Start):$($range.End)"
            continue
        }

        $state = Get-ResumeState $segIdx
        if ($state.Complete) {
            Info "SEG $segIdx finished, skipping"
            continue
        }

        if ($segIdx -eq $initialSegIdx -and $initialSubOverride -ge 0) {
            $subStart = $initialSubOverride
            $initialSubOverride = -1
        }
        else {
            $subStart = $state.NextSub
            if ($state.LastSub -ge 0) {
                Info "SEG $segIdx from SUB $subStart (last completed SUB $state.LastSub)"
            }
        }

        if ($subStart -lt 0) { $subStart = 0 }
        if ($subStart -ge $subCount) { continue }

        Info "SEG $segIdx | subs $subStart..$($subCount - 1)"

        for ($sub = $subStart; $sub -lt $subCount; $sub++) {
            $subRange = Get-SubRange $segStartBig $segEndBig $sub $subCount
            $startHex = BigToHex $subRange.Start
            $endHex   = BigToHex $subRange.End
            $rangeStr = "${startHex}:${endHex}"
            $outFile  = Join-Path $scanDir "seg${segIdx}_sub${sub}_found.txt"

            Info "SEG $segIdx SUB $sub / $($subCount - 1) | $rangeStr"

            $exitCode = Invoke-KeyHuntRun $rangeStr $outFile $modeFlag
            if ($exitCode -ne 0) {
                Warn "KeyHunt failed on SEG $segIdx SUB $sub"
                return $exitCode
            }

            if (Test-Path $outFile) {
                $hits = Get-Content $outFile -ErrorAction SilentlyContinue
                if ($hits) {
                    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    foreach ($hit in $hits) {
                        if ($hit.Trim()) {
                            Add-Content -Path $foundLog -Value "[$stamp] SEG $segIdx SUB $sub | $hit"
                            Ok "FOUND: $hit"
                        }
                    }
                }
            }

            Write-ScannedRecord $resumeFile $segIdx $sub $startHex $endHex

            $elapsedHours = ((Get-Date) - $checkpointTimer).TotalHours
            if ($elapsedHours -ge $saveIntervalHours) {
                Ok "Checkpoint: SEG $segIdx SUB $sub saved"
                $checkpointTimer = Get-Date
            }
        }

        Ok "SEG $segIdx complete"
    }

    Ok "All segments from $floorIndex through $($segments.Count - 1) finished."
    return 0
}

# --- Runner (auto-restart on crash / after power loss when registered in Task Scheduler) ---
$explicitStartSub = $PSBoundParameters.ContainsKey('startSub') -and $startSub -ge 0

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
try { $createdNew = $mutex.WaitOne(0) }
catch {
    Log "ERROR: Could not acquire lock: $($_.Exception.Message)"
    exit 1
}

if (!$createdNew) {
    Log "Already running. Exiting."
    exit 0
}

Log "Started | SEG $startIndex | saveInterval ${saveIntervalHours}h"

while ($true) {
    try {
        $code = Start-SegmentScan -explicitStartSub $explicitStartSub
        if ($code -eq 0) {
            Log "Finished normally."
            break
        }
        Log "Exit code $code — restart in $restartDelaySeconds s"
    }
    catch {
        Log "ERROR: $($_.Exception.Message) — restart in $restartDelaySeconds s"
    }
    Start-Sleep -Seconds $restartDelaySeconds
}

Log "Stopped."
$mutex.ReleaseMutex()
