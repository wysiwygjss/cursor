# Run:
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\Run-KeyHunt-Service.ps1" -startIndex 7790 -saveIntervalHours 6

param(
    [int]$startIndex = -1,
    [int]$startSub   = -1,
    [int]$subCount   = 53687,
    [ValidateSet("compressed", "uncompressed", "both")]
    [string]$mode = "uncompressed",
    [double]$saveIntervalHours = 2,
    [int]$restartDelaySeconds = 30
)

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

# ==================== HELPERS ====================
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

function Get-SubRange([System.Numerics.BigInteger]$segStart, [System.Numerics.BigInteger]$segEnd, [int]$subIndex, [int]$totalSubs) {
    $total = $segEnd - $segStart + 1
    $subStart = $segStart + ($total * $subIndex / $totalSubs)
    $subEnd   = $segStart + ($total * ($subIndex + 1) / $totalSubs) - 1
    return @{ Start = $subStart; End = $subEnd }
}

function Parse-ResumeLine([string]$line) {
    if (!$line) { return $null }
    $line = $line.Trim()
    if ($line -match '^SEG') { return $null }

    # 7790,776,71DB28E0E60D099E5C,71DB28E2E60D429E62,07/13/2026 05:58:33
    if ($line -match '^(\d+),(\d+),([0-9A-Fa-f]+),([0-9A-Fa-f]+),(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})$') {
        return @{
            SegIdx   = [int]$Matches[1]
            SubIdx   = [int]$Matches[2]
            StartHex = $Matches[3]
            EndHex   = $Matches[4]
        }
    }

  $parts = $line.Split(',')
    if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$' -and $parts[1] -match '^\d+$') {
        return @{ SegIdx = [int]$parts[0]; SubIdx = [int]$parts[1]; StartHex = $null; EndHex = $null }
    }
    return $null
}

function Get-LastResume([string]$resumeFile, [int]$segIdx) {
    if (!(Test-Path $resumeFile)) { return $null }
    $lines = @(Get-Content $resumeFile -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $p = Parse-ResumeLine $lines[$i]
        if ($p -and $p.SegIdx -eq $segIdx) { return $p }
    }
    return $null
}

function Get-ResumeState([int]$segIdx) {
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    $lastSub = $subCount - 1
    $state = @{ Complete = $false; NextSub = 0; LastSub = -1; File = $resumeFile }

    $p = Get-LastResume $resumeFile $segIdx
    if (!$p) { return $state }

    $state.LastSub = $p.SubIdx
    $state.NextSub = $p.SubIdx + 1
  if ($p.SubIdx -eq $lastSub) {
        $state.Complete = $true
        $state.NextSub  = $subCount
    }
    return $state
}

function Find-NextOpenSegment([int]$fromIdx, [int]$toIdx) {
    for ($i = $fromIdx; $i -lt $toIdx; $i++) {
        $s = Get-ResumeState $i
        if (!$s.Complete) {
            return @{ Found = $true; Index = $i; NextSub = $s.NextSub }
        }
    }
    return @{ Found = $false }
}

function Save-Resume([string]$resumeFile, [int]$segIdx, [int]$sub, [string]$startHex, [string]$endHex) {
    $line = "$segIdx,$sub,$startHex,$endHex,$(Format-ScanStamp)"
    Add-Content -Path $resumeFile -Value $line
    Add-Content -Path $scannedFile -Value $line
}

function Run-Scan([bool]$explicitStartSub) {
    New-Item -ItemType Directory -Force -Path $scanDir | Out-Null

    $floorIndex = if ($startIndex -ge 0) { $startIndex } else { 0 }

    if (!(Test-Path $segmentFile)) { Write-Host "Segment file missing" -ForegroundColor Red; return 1 }
    if (!(Test-Path $exe))         { Write-Host "KeyHunt not found" -ForegroundColor Red; return 1 }
    if (!(Test-Path $targetFile))  { Write-Host "Target file missing" -ForegroundColor Red; return 1 }

    $modeFlag = switch ($mode) {
        "uncompressed" { "-u" }
        "both"         { "-b" }
        default        { $null }
    }

    $segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") })
    Info "Loaded $($segments.Count) segments | save every $saveIntervalHours hour(s)"

    # --- resolve start segment + sub ---
    $seg = $startIndex
    $sub = $startSub

    if ($seg -ge 0) {
        if (!$explicitStartSub) {
            $state = Get-ResumeState $seg
            if ($state.Complete) {
                Warn "SEG $seg finished -> next segment"
                $next = Find-NextOpenSegment ($seg + 1) $segments.Count
                if ($next.Found) {
                    $seg = $next.Index
                    $sub = $next.NextSub
                    Info "Continuing SEG $seg SUB $sub"
                }
                else {
                    Ok "All segments from $floorIndex onward are complete."
                    return 0
                }
            }
            else {
                $sub = $state.NextSub
                if ($state.LastSub -ge 0) {
                    Info "Resume SEG $seg after SUB $state.LastSub -> start SUB $sub"
                }
                else {
                    Info "SEG $seg start SUB 0"
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
    if ($seg -ge $segments.Count) { Write-Host "Invalid segment $seg" -ForegroundColor Red; return 1 }
    if ($sub -lt 0) { $sub = 0 }

    $checkpointTimer = Get-Date
    $firstSeg = $seg
    $firstSub = if ($explicitStartSub) { $sub } else { -1 }

    # --- segment loop: 7790, 7791, 7792 ... ---
    for ($segIdx = $seg; $segIdx -lt $segments.Count; $segIdx++) {
        if ($segIdx -lt $floorIndex) { continue }

        $range = Parse-SegmentRange $segments[$segIdx]
        if (!$range) { Warn "Skip invalid line at $segIdx"; continue }

        $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
        $segStartBig = HexToBig $range.Start
        $segEndBig   = HexToBig $range.End
        if ($segEndBig -lt $segStartBig) { Warn "Bad range SEG $segIdx"; continue }

        $state = Get-ResumeState $segIdx
        if ($state.Complete) {
            Info "SEG $segIdx complete -> next segment"
            continue
        }

        # sub start for this segment
        if ($segIdx -eq $firstSeg -and $firstSub -ge 0) {
            $subStart = $firstSub
            $firstSub = -1
        }
        else {
            $subStart = $state.NextSub
        }
        if ($subStart -lt 0) { $subStart = 0 }
        if ($subStart -ge $subCount) { continue }

        Info "SEG $segIdx | $($range.Start):$($range.End) | SUB $subStart to $($subCount - 1)"

        # --- sub loop: save resume after each sub, then next sub ---
        for ($s = $subStart; $s -lt $subCount; $s++) {
            $subRange = Get-SubRange $segStartBig $segEndBig $s $subCount
            $startHex  = BigToHex $subRange.Start
            $endHex    = BigToHex $subRange.End
            $rangeStr  = "${startHex}:${endHex}"
            $outFile   = Join-Path $scanDir "seg${segIdx}_sub${s}_found.txt"

            Info "SEG $segIdx SUB $s / $($subCount - 1) | $rangeStr"

            $argList = @(
                "-t", "0", "-g", "-m", "addresses", "--coin", "BTC",
                "--range", $rangeStr, "-i", $targetFile, "-o", $outFile
            )
            if ($modeFlag) { $argList += $modeFlag }

            $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Warn "KeyHunt exit $($proc.ExitCode) SEG $segIdx SUB $s"
                return $proc.ExitCode
            }

            if (Test-Path $outFile) {
                $hits = Get-Content $outFile -ErrorAction SilentlyContinue
                if ($hits) {
                    foreach ($hit in $hits) {
                        if ($hit.Trim()) {
                            Add-Content -Path $foundLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] SEG $segIdx SUB $s | $hit"
                            Ok "FOUND: $hit"
                        }
                    }
                }
            }

            # save resume -> moves to next sub on loop continue
            Save-Resume $resumeFile $segIdx $s $startHex $endHex

            if (((Get-Date) - $checkpointTimer).TotalHours -ge $saveIntervalHours) {
                Ok "Checkpoint SEG $segIdx SUB $s"
                $checkpointTimer = Get-Date
            }
        }

        # all subs done -> loop continues to next segment (7790 -> 7791)
        Ok "SEG $segIdx complete -> next segment"
    }

    Ok "Scan finished."
    return 0
}

# ==================== RUNNER (restarts after crash) ====================
$explicitStartSub = $PSBoundParameters.ContainsKey('startSub') -and $startSub -ge 0

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (!$mutex.WaitOne(0)) {
    Log "Already running."
    exit 0
}

Log "Started | startIndex=$startIndex saveInterval=${saveIntervalHours}h"

while ($true) {
    try {
        $code = Run-Scan -explicitStartSub $explicitStartSub
        if ($code -eq 0) { Log "Done."; break }
        Log "Exit $code — retry in ${restartDelaySeconds}s"
    }
    catch {
        Log "Error: $($_.Exception.Message) — retry in ${restartDelaySeconds}s"
    }
    Start-Sleep -Seconds $restartDelaySeconds
}

$mutex.ReleaseMutex()
Log "Stopped."
