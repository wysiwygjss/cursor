# KeyHunt Segment Scanner v3.4 - Production Grade
# Requires: PowerShell 5.1+ or PowerShell Core 7.x
# Save as: C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1
#
# EXIT CODES:
#   0 = Success (all segments complete)
#   1 = Error (initialization failed, runtime error after retries, invalid parameters)
#   2 = Already running (mutex conflict - not an error, just skip)
#
# Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "v3.ps1" -startIndex 7790 -saveIntervalHours 6 -RegisterAutoStart

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
    [string]$targetFile = "",
    [string]$suiteRoot = "",
    [int]$maxConsecutiveErrors = 5
)

$global:ScriptExitCode = 0

# ==================== VALIDATION ====================
if ($PSBoundParameters.ContainsKey("startSub") -and $startSub -ge 0 -and $startIndex -lt 0) {
    Write-Error "-startSub requires -startIndex (e.g. -startIndex 7790 -startSub 776)"
    exit 1
}

if ($saveIntervalHours -le 0) {
    Write-Error "saveIntervalHours must be greater than 0"
    exit 1
}
if ($keysPerSecond -le 0) {
    Write-Error "keysPerSecond must be greater than 0"
    exit 1
}
if ($restartDelaySeconds -lt 0) {
    Write-Error "restartDelaySeconds cannot be negative"
    exit 1
}
if ($maxConsecutiveErrors -lt 1) {
    Write-Error "maxConsecutiveErrors must be at least 1"
    exit 1
}

if ($hoursPerSub -le 0) { $hoursPerSub = $saveIntervalHours }
if ($PSBoundParameters.ContainsKey('saveIntervalHours') -and !$PSBoundParameters.ContainsKey('subCount')) {
    $autoSubSize = $true
}

$ErrorActionPreference = "Stop"

# ==================== PATHS ====================
if ([string]::IsNullOrWhiteSpace($suiteRoot)) {
    $suiteRoot = $env:KEYHUNT_SUITE_ROOT
}
if ([string]::IsNullOrWhiteSpace($suiteRoot)) {
    $suiteRoot = "C:\Users\Admin\Documents\KeyhuntSuite"
}

if ($suiteRoot -match '\s') {
    Write-Error "suiteRoot path cannot contain spaces: $suiteRoot"
    exit 1
}

$wrapperDir    = Join-Path $suiteRoot "Wrappers"
$scriptSelf    = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $wrapperDir "v3.ps1" }
$segmentFile   = Join-Path $suiteRoot "segment71_10000.txt"
$exe           = Join-Path $suiteRoot "Bin\KeyHunt-Cuda.exe"
$targetDir     = Join-Path $suiteRoot "Data\btc"
$defaultTarget = Join-Path $targetDir "hash160_sorted.bin"
$scanDir       = Join-Path $suiteRoot "Scanned_Segments"
$foundLog      = Join-Path $scanDir "Found_All.txt"
$scannedFile   = Join-Path $scanDir "Scanned_Segments.txt"
$logFile       = Join-Path $wrapperDir "runner.log"
$mutexName     = "Global\KeyHuntSegmentScanner"

# ==================== LOGGING ====================
function Log($m) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 10MB) {
            $backup = "$logFile.old"
            Move-Item -Path $logFile -Destination $backup -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to write to log: $_"
    }
    Write-Host $line
}

function Now { Get-Date -Format "HH:mm:ss" }
function Info($m) { Write-Host "[$(Now)] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[$(Now)] $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "[$(Now)] $m" -ForegroundColor Green }
function Err($m)  { Write-Host "[$(Now)] $m" -ForegroundColor Red }

# ==================== ARITHMETIC (OVERFLOW-SAFE) ====================
function Test-BigIntegerOps {
    try {
        $a = [System.Numerics.BigInteger]::Parse("10000000000000000000")
        $b = [System.Numerics.BigInteger]::Parse("3")
        $c = [System.Numerics.BigInteger]::op_Division($a, $b)
        $d = [System.Numerics.BigInteger]::Parse("100")
        $e = [System.Numerics.BigInteger]::op_Division($d, [System.Numerics.BigInteger]::Parse("3"))

        if ($c.ToString() -ne "3333333333333333333" -or $e.ToString() -ne "33") {
            throw "BigInteger division test failed"
        }
        return $true
    }
    catch {
        Err "BigInteger arithmetic test failed: $_"
        return $false
    }
}

if (!(Test-BigIntegerOps)) {
    exit 1
}

function ConvertTo-BigIntegerSafe([double]$value) {
    if ($value -lt 0) { $value = 0 }
    try {
        if ($value -le [int64]::MaxValue) {
            return [System.Numerics.BigInteger][int64][math]::Truncate($value)
        }
        return [System.Numerics.BigInteger]::Parse([math]::Truncate($value).ToString("F0"))
    }
    catch {
        return [System.Numerics.BigInteger]::Parse([math]::Truncate($value).ToString("F0"))
    }
}

function Get-ChunkKeyCount {
    $raw = $keysPerSecond * $saveIntervalHours * 3600.0
    $n = ConvertTo-BigIntegerSafe $raw
    if ($n -lt 1) { $n = 1 }
    return $n
}

function Get-SegmentSubCount(
    [System.Numerics.BigInteger]$segStart,
    [System.Numerics.BigInteger]$segEnd
) {
    if (!$autoSubSize) { return $subCount }

    $total = $segEnd - $segStart + 1
    $rawKeysPerSub = $keysPerSecond * $hoursPerSub * 3600.0
    $keysPerSub = ConvertTo-BigIntegerSafe $rawKeysPerSub

    if ($keysPerSub -le 0) { return $subCount }

    $n = ($total + $keysPerSub - 1) / $keysPerSub

    if ($n -lt 1) { return 1 }
    if ($n -gt [int]::MaxValue) { return [int]::MaxValue }

    return [int]$n
}

# ==================== HEX / RANGE ====================
function HexToBig($h) {
    $clean = ($h -replace '\s', '').Trim()
    if ($clean -match '^0x') { $clean = $clean.Substring(2) }

    if ($clean -notmatch '^[0-9A-Fa-f]+$') {
        throw "Invalid hex string: $h"
    }

    if ($clean.Length % 2 -ne 0) {
        $clean = "0" + $clean
    }

    [System.Numerics.BigInteger]::Parse("0" + $clean, [System.Globalization.NumberStyles]::HexNumber)
}

function BigToHex($n) {
    $hex = $n.ToString("X")
    if ($hex.Length % 2 -ne 0) {
        $hex = "0" + $hex
    }
    $hex
}

function Format-ScanStamp { Get-Date -Format "MM/dd/yyyy HH:mm:ss" }

function Parse-SegmentRange($line) {
    $line = $line.Trim()
    if (!$line -or $line.StartsWith("#")) { return $null }

    if ($line -match '^([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)$') {
        return @{ Start = $Matches[1].Trim(); End = $Matches[2].Trim() }
    }
    elseif ($line -match '^(\d+)\s*,\s*([0-9A-Fa-f]+)\s*,\s*([0-9A-Fa-f]+)') {
        return @{ Start = $Matches[2].Trim(); End = $Matches[3].Trim() }
    }
    else {
        Warn "Unrecognized segment line: $line"
        return $null
    }
}

function Get-SubRange(
    [System.Numerics.BigInteger]$segStart,
    [System.Numerics.BigInteger]$segEnd,
    [int]$subIndex,
    [int]$totalSubs
) {
    if ($totalSubs -le 0) { throw "totalSubs must be positive" }
    if ($subIndex -lt 0 -or $subIndex -ge $totalSubs) { throw "subIndex out of range" }

    $total = $segEnd - $segStart + 1
    [System.Numerics.BigInteger]$bigSubIndex = $subIndex
    [System.Numerics.BigInteger]$bigTotalSubs = $totalSubs

    $subStart = $segStart + ($total * $bigSubIndex) / $bigTotalSubs
    $subEnd   = $segStart + ($total * ($bigSubIndex + 1)) / $bigTotalSubs - 1

    if ($subStart -lt $segStart) { $subStart = $segStart }
    if ($subEnd -gt $segEnd) { $subEnd = $segEnd }

    return @{ Start = $subStart; End = $subEnd }
}

function Get-RangeChunks(
    [System.Numerics.BigInteger]$start,
    [System.Numerics.BigInteger]$end,
    [System.Numerics.BigInteger]$chunkSize
) {
    if ($chunkSize -le 0) { throw "chunkSize must be positive" }

    $list = New-Object System.Collections.ArrayList
    $pos = $start
    while ($pos -le $end) {
        $chunkEnd = $pos + $chunkSize - 1
        if ($chunkEnd -gt $end) { $chunkEnd = $end }
        [void]$list.Add(@{ Start = $pos; End = $chunkEnd })
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

    [System.Numerics.BigInteger]$bigTotalSubs = $totalSubs
    $idx = [int](($offset * $bigTotalSubs) / $total)

    if ($idx -ge $totalSubs) { $idx = $totalSubs - 1 }
    if ($idx -lt 0) { $idx = 0 }

    return $idx
}

# ==================== FILE OPERATIONS ====================
function Initialize-Directory([string]$path) {
    if (!(Test-Path $path)) {
        try {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
        catch {
            throw "Failed to create directory: $path - $($_.Exception.Message)"
        }
    }
}

function Resolve-TargetFile {
    if ($targetFile -and (Test-Path $targetFile)) {
        if ($targetFile -match '\s') {
            throw "Target file path cannot contain spaces: $targetFile"
        }
        return $targetFile
    }

    if (Test-Path $defaultTarget) { return $defaultTarget }

    Initialize-Directory $targetDir

    $found = @(Get-ChildItem -Path $suiteRoot -Recurse -Filter "hash160_sorted.bin" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'puzzle|_puzzle' })

    if ($found.Count -ge 1) {
        $pick = $found | Where-Object { $_.FullName -notmatch '\s' } | Select-Object -First 1
        if (!$pick) {
            throw "Found target file(s) but all contain spaces in path. KeyHunt requires paths without spaces."
        }
        if ($pick.FullName -ne $defaultTarget) {
            Copy-Item -Path $pick.FullName -Destination $defaultTarget -Force
            Info "Copied target to: $defaultTarget"
        }
        return $defaultTarget
    }

    return $null
}

# ==================== RESUME ====================
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
            Timestamp = [datetime]::ParseExact($Matches[5], "MM/dd/yyyy HH:mm:ss", $null)
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
            Timestamp = [datetime]$parts[2].Trim()
        }
    }

    return $null
}

function Get-MaxResumeEntry([string]$resumeFile, [int]$segIdx) {
    if (!(Test-Path $resumeFile)) { return $null }

    $best = $null
    $lines = @()
    $fs = $null
    $sr = $null

    try {
        $fs = [System.IO.File]::Open($resumeFile, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $sr = New-Object System.IO.StreamReader($fs)
        while ($null -ne ($line = $sr.ReadLine())) {
            $lines += $line
        }
    }
    catch {
        $lines = @(Get-Content $resumeFile -ErrorAction SilentlyContinue)
    }
    finally {
        if ($sr) { $sr.Close() }
        if ($fs) { $fs.Close() }
    }

    foreach ($line in $lines) {
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
        try {
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
        catch {
            Warn "Error calculating sub-range: $_"
            $state.Partial = $true
            $state.NextSub = $maxEntry.SubIdx
        }
    }
    else {
        $state.NextSub = $maxEntry.SubIdx + 1
        $subComplete = $true
    }

    if ($autoSubSize -and $maxEntry.EndHex) {
        try {
            $continueKey = (HexToBig $maxEntry.EndHex) + 1
            if ($continueKey -le $segEnd) {
                $offset = $continueKey - $segStart
                $mappedSub = Get-SubIndexForOffset $segStart $segEnd $offset $segSubCount
                $state.NextSub = $mappedSub
                $state.LastSub = $mappedSub
                if (!$subComplete) {
                    $state.Partial = $true
                }
            }
        }
        catch {
            Warn "Error in autoSubSize remapping: $_"
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
        try {
            $st = HexToBig $range.Start
            $en = HexToBig $range.End
            $ssc = Get-SegmentSubCount $st $en
            $state = Get-ResumeState $i $ssc $st $en
            if (!$state.Complete) {
                return @{ Found = $true; Index = $i; NextSub = $state.NextSub }
            }
        }
        catch {
            Warn "Error checking segment $i`: $_"
            continue
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
    $endHexUpper = $endHex.ToUpper()
    $acquired = $false
    $mutex = $null

    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\KeyHuntResume_$segIdx")
        $acquired = $mutex.WaitOne(5000)
        if (!$acquired) {
            Warn "Resume mutex timeout for SEG $segIdx - skipping write"
            return
        }

        $maxEntry = $null
        if (Test-Path $resumeFile) {
            $maxEntry = Get-MaxResumeEntry $resumeFile $segIdx
        }

        if ($maxEntry -and $sub -lt $maxEntry.SubIdx) {
            Warn "Skip resume write SUB $sub (highest completed SUB $($maxEntry.SubIdx))"
            return
        }
        if ($maxEntry -and $sub -eq $maxEntry.SubIdx -and $maxEntry.EndHex -and $maxEntry.EndHex.ToUpper() -eq $endHexUpper) {
            Warn "Skip duplicate resume line for SUB $sub"
            return
        }

        Add-Content -Path $resumeFile -Value $line
        Add-Content -Path $scannedFile -Value $line
    }
    catch {
        Warn "Failed to save resume: $_"
        try {
            Add-Content -Path $resumeFile -Value $line -ErrorAction SilentlyContinue
            Add-Content -Path $scannedFile -Value $line -ErrorAction SilentlyContinue
        }
        catch {
            Warn "Critical: Could not write resume file"
        }
    }
    finally {
        if ($mutex) {
            if ($acquired) {
                [void]$mutex.ReleaseMutex()
            }
            $mutex.Dispose()
        }
    }
}

function Write-FoundHits([int]$segIdx, [int]$sub, [string]$outFile) {
    if (!(Test-Path $outFile)) { return }

    $hits = @(Get-Content $outFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
    if ($hits.Count -eq 0) { return }

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    foreach ($hit in $hits) {
        $foundMsg = "[{0}] SEG {1} SUB {2} | {3}" -f $stamp, $segIdx, $sub, $hit.Trim()
        Add-Content -Path $foundLog -Value $foundMsg
        Ok "FOUND: $($hit.Trim())"
    }

    Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue
}

# ==================== KEYHUNT ====================
function Invoke-KeyHunt([string]$rangeStr, [string]$outFile, [string]$modeFlag) {
    if (!(Test-Path $exe)) {
        throw "KeyHunt executable not found: $exe"
    }

    if (Test-Path $outFile) {
        Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue
    }

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
        $cmdPreview = "$exe " + ($argList | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '
        Info "KeyHunt: $cmdPreview"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = $null

        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru
            $proc.WaitForExit()
            $lastExit = $proc.ExitCode
        }
        catch {
            Warn "Failed to start KeyHunt: $_"
            $lastExit = -1
        }
        finally {
            if ($proc -and !$proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
            $sw.Stop()
        }

        Info ("KeyHunt finished in {0:N1}s exit {1}" -f $sw.Elapsed.TotalSeconds, $lastExit)

        if ($lastExit -eq 0) { return 0 }

        Warn "KeyHunt exit $lastExit (attempt $attempt/$keyHuntRetries)"
        if ($attempt -lt $keyHuntRetries) {
            Start-Sleep -Seconds $keyHuntRetryDelaySeconds
        }
    }

    return $lastExit
}

# ==================== AUTO-START ====================
function Invoke-SchTasks([string[]]$schArgs) {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $output = & schtasks.exe @schArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    return @{ Code = $code; Output = $output }
}

function Register-AutoStartTask {
    if (!(Test-Path $scriptSelf)) {
        Write-Error "Script not found: $scriptSelf"
        return $false
    }

    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptSelf`" -startIndex $startIndex -saveIntervalHours $saveIntervalHours -mode $mode"
    if ($startSub -ge 0) { $argString += " -startSub $startSub" }
    if ($targetFile) { $argString += " -targetFile `"$targetFile`"" }
    if ($autoSubSize) { $argString += " -autoSubSize -hoursPerSub $hoursPerSub -keysPerSecond $keysPerSecond" }
    elseif ($subCount -ne 53687) { $argString += " -subCount $subCount" }
    if ($suiteRoot -ne "C:\Users\Admin\Documents\KeyhuntSuite") {
        $argString += " -suiteRoot `"$suiteRoot`""
    }
    if ($maxConsecutiveErrors -ne 5) { $argString += " -maxConsecutiveErrors $maxConsecutiveErrors" }
    if ($keyHuntRetries -ne 5) { $argString += " -keyHuntRetries $keyHuntRetries" }
    if ($keyHuntRetryDelaySeconds -ne 60) { $argString += " -keyHuntRetryDelaySeconds $keyHuntRetryDelaySeconds" }
    if ($restartDelaySeconds -ne 30) { $argString += " -restartDelaySeconds $restartDelaySeconds" }

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
            -Description "KeyHunt v3.4 - auto-start after reboot, resume highest SUB per segment" | Out-Null
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
                -Description "KeyHunt v3.4 - auto-start at logon, resume highest SUB per segment" | Out-Null
        }
        catch {
            Warn "Register-ScheduledTask failed; trying schtasks..."
            if (Register-AutoStartViaSchTasks $argString) { return $true }
            Write-Error "Could not register scheduled task: $($_.Exception.Message)"
            return $false
        }
    }

    Info "Registered '$taskName' -> v3.ps1"
    Info "  startIndex=$startIndex saveIntervalHours=$saveIntervalHours mode=$mode"
    return $true
}

function Register-AutoStartViaSchTasks([string]$argString) {
    $null = Invoke-SchTasks @('/Delete', '/TN', $taskName, '/F')
    $tr = "powershell.exe $argString"
    $result = Invoke-SchTasks @('/Create', '/TN', $taskName, '/TR', $tr, '/SC', 'ONLOGON', '/RL', 'LIMITED', '/F')
    if ($result.Code -eq 0) {
        Info "Registered '$taskName' via schtasks (starts at logon)."
        return $true
    }
    Err "schtasks failed: $($result.Output)"
    return $false
}

function Unregister-AutoStartTask {
    $null = Invoke-SchTasks @('/Delete', '/TN', $taskName, '/F')
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        Info "Removed '$taskName'."
    }
    else {
        Warn "Task '$taskName' not found."
    }
}

# ==================== MAIN SCAN ====================
function Run-Scan([bool]$explicitStartSub) {
    Initialize-Directory $scanDir

    $floorIndex = if ($startIndex -ge 0) { $startIndex } else { 0 }

    if (!(Test-Path $segmentFile)) {
        throw "Segment file missing: $segmentFile"
    }
    if (!(Test-Path $exe)) {
        throw "KeyHunt not found: $exe"
    }
    if (!$targetFile) {
        throw "Target file not found. Copy hash160_sorted.bin to Data\btc\ or pass -targetFile"
    }
    Info "Target: $targetFile"

    $modeFlag = switch ($mode) {
        "uncompressed" { "-u" }
        "both"         { "-b" }
        default        { $null }
    }

    $segments = @(Get-Content $segmentFile | Where-Object { $_.Trim() -and !$_.Trim().StartsWith("#") })
    Info ("v3.4 | segments: {0} | floor: {1} | save+sub every {2}h | autoSubSize={3}" -f $segments.Count, $floorIndex, $saveIntervalHours, $autoSubSize)
    Info "Resume: highest completed SUB per segment (stray low lines ignored)"

    $seg = $startIndex
    $sub = $startSub

    if ($seg -ge 0) {
        if (!$explicitStartSub) {
            try {
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
            catch {
                throw "Error initializing segment $seg`: $_"
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
        throw "Invalid segment index $seg (max: $($segments.Count - 1))"
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

        try {
            $segStartBig = HexToBig $range.Start
            $segEndBig   = HexToBig $range.End

            if ($segEndBig -lt $segStartBig) {
                Warn "Invalid range SEG $segIdx (end < start)"
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
                    try {
                        $resumeEnd = HexToBig $state.EndHex
                        $runStart = $resumeEnd + 1
                        if ($runStart -gt $runEnd) { continue }
                    }
                    catch {
                        Warn "Error resuming partial sub: $_"
                    }
                }

                $chunks = @(Get-RangeChunks $runStart $runEnd $chunkKeys)
                $chunkIdx = 0
                foreach ($chunk in $chunks) {
                    $chunkIdx++
                    $startHex = BigToHex $chunk.Start
                    $endHex   = BigToHex $chunk.End
                    $rangeStr = "${startHex}:${endHex}"
                    $outFile  = Join-Path $scanDir "seg${segIdx}_sub${s}_found.txt"

                    Info ("SEG $segIdx SUB $s/$($segSubCount - 1) chunk $chunkIdx/$($chunks.Count) $rangeStr")

                    $exitCode = Invoke-KeyHunt $rangeStr $outFile $modeFlag
                    if ($exitCode -ne 0) {
                        Warn "KeyHunt failed SEG $segIdx SUB $s"
                        return $exitCode
                    }

                    Write-FoundHits $segIdx $s $outFile

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
        catch {
            Warn "Error processing segment $segIdx`: $_"
            continue
        }
    }

    Ok "Scan finished."
    return 0
}

# ==================== ENTRY POINT ====================
$explicitStartSub = $PSBoundParameters.ContainsKey("startSub") -and $startSub -ge 0

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
        Err "Auto-start registration failed: $($_.Exception.Message)"
    }
}

try {
    Initialize-Directory $wrapperDir
    $targetFile = Resolve-TargetFile
    if (!$targetFile -or !(Test-Path $targetFile)) {
        throw "Target file not found. Copy hash160_sorted.bin to Data\btc\ or pass -targetFile"
    }
}
catch {
    Err "Initialization failed: $_"
    exit 1
}

if ($RegisterAutoStart -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Info "Running with Administrator privileges"
}

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (!$mutex.WaitOne(0)) {
    Log "v3.4 already running."
    exit 2
}

Log ("v3.4 started | startIndex={0} | saveInterval={1}h | mode={2} | suiteRoot={3}" -f $startIndex, $saveIntervalHours, $mode, $suiteRoot)

$useExplicitSub = $explicitStartSub
$consecutiveErrors = 0

while ($true) {
    try {
        $code = Run-Scan -explicitStartSub $useExplicitSub
        $useExplicitSub = $false

        if ($code -eq 0) {
            Log "v3.4 finished normally."
            $global:ScriptExitCode = 0
            $consecutiveErrors = 0
            break
        }

        $consecutiveErrors++
        Log "v3.4 exit $code - retry in ${restartDelaySeconds}s (resume from highest SUB)"
        Log "Consecutive errors: $consecutiveErrors/$maxConsecutiveErrors"

        if ($consecutiveErrors -ge $maxConsecutiveErrors) {
            Err "Too many consecutive errors. Stopping."
            $global:ScriptExitCode = 1
            break
        }
    }
    catch {
        $consecutiveErrors++
        Err "v3.4 error: $($_.Exception.Message) - retry in ${restartDelaySeconds}s"
        Log "Consecutive errors: $consecutiveErrors/$maxConsecutiveErrors"

        if ($consecutiveErrors -ge $maxConsecutiveErrors) {
            Err "Too many consecutive errors. Stopping."
            $global:ScriptExitCode = 1
            break
        }
        $useExplicitSub = $false
    }
    Start-Sleep -Seconds $restartDelaySeconds
}

$mutex.ReleaseMutex()
Log "v3.4 stopped with exit code $global:ScriptExitCode"
exit $global:ScriptExitCode
