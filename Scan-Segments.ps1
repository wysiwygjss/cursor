param(
    [int]$startIndex = -1,
    [int]$startSub   = -1,
    [int]$subCount   = 53687,
    [ValidateSet("compressed", "uncompressed", "both")]
    [string]$mode = "uncompressed",
    [double]$saveIntervalHours = 2,
    [int]$keyHuntRetries = 5,
    [int]$keyHuntRetryDelaySeconds = 60
)

# ==================== PATHS ====================
$segmentFile = "C:\Users\Admin\Documents\KeyhuntSuite\segment71_10000.txt"
$exe         = "C:\Users\Admin\Documents\KeyhuntSuite\Bin\KeyHunt-Cuda.exe"
$targetFile  = "C:\Users\Admin\Documents\KeyhuntSuite\bitcoincore_utxo\hash160_sorted.bin"
$scanDir     = "C:\Users\Admin\Documents\KeyhuntSuite\Scanned_Segments"
$foundLog    = Join-Path $scanDir "Found_All.txt"

New-Item -ItemType Directory -Force -Path $scanDir | Out-Null

# Floor: never scan below this segment index (set from -startIndex when provided)
$floorIndex = if ($startIndex -ge 0) { $startIndex } else { 0 }

# ==================== HELPERS ====================
function Now { Get-Date -Format "HH:mm:ss" }
function Info($m) { Write-Host "[$(Now)] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[$(Now)] $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "[$(Now)] $m" -ForegroundColor Green }

function HexToBig($h) {
    $clean = ($h -replace '\s', '').Trim()
    if ($clean -match '^0x') { $clean = $clean.Substring(2) }
    [System.Numerics.BigInteger]::Parse("0" + $clean, [System.Globalization.NumberStyles]::HexNumber)
}

function BigToHex($n) {
    $n.ToString("X")
}

function Parse-SegmentRange($line) {
    $line = $line.Trim()
    if (!$line -or $line.StartsWith("#")) { return $null }

    if ($line -match ':') {
        $parts = $line.Split(':')
    }
    elseif ($line -match ',') {
        $parts = $line.Split(',')
        if ($parts.Count -ge 3) {
            $parts = @($parts[1], $parts[2])
        }
    }
    else {
        Warn "Unrecognized segment line format: $line"
        return $null
    }

    if ($parts.Count -lt 2) {
        Warn "Segment line needs start and end: $line"
        return $null
    }

    return @{
        Start = $parts[0].Trim()
        End   = $parts[1].Trim()
    }
}

function Get-SubRange([System.Numerics.BigInteger]$segStart, [System.Numerics.BigInteger]$segEnd, [int]$subIndex, [int]$totalSubs) {
    $total = $segEnd - $segStart + 1
    $subStart = $segStart + ($total * $subIndex / $totalSubs)
    $subEnd   = $segStart + ($total * ($subIndex + 1) / $totalSubs) - 1
    return @{ Start = $subStart; End = $subEnd }
}

function Get-ResumeState([int]$segIdx) {
    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    $state = @{
        Complete = $false
        NextSub  = 0
        File     = $resumeFile
    }

    if (!(Test-Path $resumeFile)) {
        return $state
    }

    $lastLine = Get-Content $resumeFile -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (!$lastLine) {
        return $state
    }

    if ($lastLine -match '^SEG.*,DONE') {
        $state.Complete = $true
        $state.NextSub  = $subCount
        return $state
    }

    if ($lastLine -match '^SEG') {
        return $state
    }

    $parts = $lastLine.Split(',')
    if ($parts.Count -ge 2) {
        $state.NextSub = [int]$parts[1] + 1
        if ($state.NextSub -ge $subCount) {
            $state.Complete = $true
        }
    }

    return $state
}

function Find-NextIncompleteSegment([int]$fromIndex, [int]$toIndex) {
    for ($i = $fromIndex; $i -lt $toIndex; $i++) {
        $state = Get-ResumeState $i
        if (!$state.Complete) {
            return @{
                Found  = $true
                Index  = $i
                NextSub = $state.NextSub
            }
        }
    }
    return @{ Found = $false; Index = -1; NextSub = 0 }
}

function Write-ResumeProgress([string]$resumeFile, [int]$segIdx, [int]$sub) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $resumeFile -Value "$segIdx,$sub,$stamp"
}

function Write-ResumeSegmentDone([string]$resumeFile, [int]$segIdx) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $resumeFile -Value "SEG,$segIdx,DONE,$stamp"
}

function Write-ResumeSegmentStart([string]$resumeFile, [int]$segIdx) {
    if (Test-Path $resumeFile) {
        return
    }
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $resumeFile -Value "SEG,$segIdx,$stamp"
}

function Invoke-KeyHunt([string]$rangeStr, [string]$outFile) {
    $argList = @(
        "-t", "0",
        "-g",
        "-m", "addresses",
        "--coin", "BTC",
        "--range", $rangeStr,
        "-i", $targetFile,
        "-o", $outFile
    )

    if ($modeFlag) {
        $argList += $modeFlag
    }

    for ($attempt = 1; $attempt -le $keyHuntRetries; $attempt++) {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            return 0
        }

        Warn "KeyHunt exit code $($proc.ExitCode) (attempt $attempt/$keyHuntRetries)"
        if ($attempt -lt $keyHuntRetries) {
            Info "Retrying in $keyHuntRetryDelaySeconds second(s)..."
            Start-Sleep -Seconds $keyHuntRetryDelaySeconds
        }
    }

    return $proc.ExitCode
}

# ==================== VALIDATION ====================
if (!(Test-Path $segmentFile)) { Write-Host "Segment file missing: $segmentFile" -ForegroundColor Red; exit 1 }
if (!(Test-Path $exe))         { Write-Host "KeyHunt not found: $exe" -ForegroundColor Red; exit 1 }
if (!(Test-Path $targetFile))  { Write-Host "Target file missing: $targetFile" -ForegroundColor Red; exit 1 }

# ==================== MODE FLAG ====================
$modeFlag = switch ($mode) {
    "uncompressed" { "-u" }
    "both"         { "-b" }
    default        { $null }
}

# ==================== LOAD SEGMENTS ====================
$segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") })
Info "Loaded $($segments.Count) segments"
Info "Save interval set to $saveIntervalHours hour(s)"
Info "Floor segment index: $floorIndex (scan continues through all segments until stopped)"

# ==================== AUTO-RESUME ====================
if ($startIndex -ge 0) {
  if ($startSub -lt 0) {
        $state = Get-ResumeState $startIndex

        if ($state.Complete) {
            Warn "SEG $startIndex already complete -> looking for next incomplete segment"
            $next = Find-NextIncompleteSegment ($startIndex + 1) $segments.Count
            if ($next.Found) {
                $startIndex = $next.Index
                $startSub   = $next.NextSub
                Info "Continuing at SEG $startIndex SUB $startSub"
            }
            else {
                Ok "All segments from floor $floorIndex through $($segments.Count - 1) are complete."
                exit 0
            }
        }
        else {
            $startSub = $state.NextSub
            Info "Resuming SEG $startIndex from SUB $startSub"
        }
    }
    else {
        Info "Using explicit startSub $startSub for SEG $startIndex"
    }
}
else {
    $next = Find-NextIncompleteSegment $floorIndex $segments.Count
    if ($next.Found) {
        $startIndex = $next.Index
        if ($startSub -lt 0) {
            $startSub = $next.NextSub
        }
        Info "Auto-resume: SEG $startIndex from SUB $startSub"
    }
    else {
        Ok "All segments from floor $floorIndex onward are complete."
        exit 0
    }
}

if ($startIndex -lt $floorIndex) {
    $startIndex = $floorIndex
    $startSub   = 0
    Warn "Adjusted start to floor SEG $startIndex"
}

if ($startIndex -ge $segments.Count) {
    Write-Host "Invalid startIndex $startIndex (segment count $($segments.Count))" -ForegroundColor Red
    exit 1
}

if ($startSub -lt 0) { $startSub = 0 }

# ==================== MAIN SCAN LOOP ====================
$checkpointTimer = Get-Date

for ($segIdx = $startIndex; $segIdx -lt $segments.Count; $segIdx++) {
    if ($segIdx -lt $floorIndex) {
        continue
    }

    $range = Parse-SegmentRange $segments[$segIdx]
    if (!$range) {
        Warn "Skipping invalid segment line at index $segIdx"
        continue
    }

    $resumeFile = Join-Path $scanDir "$segIdx-resume.txt"
    $segStartBig = HexToBig $range.Start
    $segEndBig   = HexToBig $range.End

    if ($segEndBig -lt $segStartBig) {
        Warn "SEG $segIdx has invalid range $($range.Start):$($range.End)"
        continue
    }

    if ($segIdx -eq $startIndex) {
        $subStart = $startSub
    }
    else {
        $subStart = 0
    }

    $state = Get-ResumeState $segIdx
    if ($state.Complete) {
        Info "SEG $segIdx already complete, skipping"
        continue
    }

    if ($subStart -ge $subCount) {
        Info "SEG $segIdx SUB range exhausted, skipping"
        continue
    }

    Write-ResumeSegmentStart $resumeFile $segIdx
    Info "SEG $segIdx range $($range.Start):$($range.End) | subs $subStart..$($subCount - 1)"

    for ($sub = $subStart; $sub -lt $subCount; $sub++) {
        $subRange  = Get-SubRange $segStartBig $segEndBig $sub $subCount
        $rangeStr  = "$(BigToHex $subRange.Start):$(BigToHex $subRange.End)"
        $outFile   = Join-Path $scanDir "seg${segIdx}_sub${sub}_found.txt"

        Info "SEG $segIdx SUB $sub / $($subCount - 1) | range $rangeStr"

        $exitCode = Invoke-KeyHunt $rangeStr $outFile
        if ($exitCode -ne 0) {
            Warn "KeyHunt failed after $keyHuntRetries attempts on SEG $segIdx SUB $sub — exiting for outer restart"
            exit $exitCode
        }

        if (Test-Path $outFile) {
            $hits = Get-Content $outFile -ErrorAction SilentlyContinue
            if ($hits) {
                $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                foreach ($hit in $hits) {
                    if ($hit.Trim()) {
                        Add-Content -Path $foundLog -Value "[$stamp] SEG $segIdx SUB $sub | $hit"
                        Ok "FOUND in SEG $segIdx SUB $sub : $hit"
                    }
                }
            }
        }

        Write-ResumeProgress $resumeFile $segIdx $sub

        $elapsedHours = ((Get-Date) - $checkpointTimer).TotalHours
        if ($elapsedHours -ge $saveIntervalHours) {
            Ok "Checkpoint after $([math]::Round($elapsedHours, 2)) hour(s): SEG $segIdx SUB $sub saved"
            $checkpointTimer = Get-Date
        }
    }

    Write-ResumeSegmentDone $resumeFile $segIdx
    Ok "SEG $segIdx complete — continuing to next segment"
}

Ok "All segments from $floorIndex through $($segments.Count - 1) finished."
