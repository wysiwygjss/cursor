# Outer runner: restarts the scan script after crashes or power recovery (via Task Scheduler).
# Run once manually or register with Register-KeyHunt-Startup.ps1

param(
    [int]$startIndex = 7790,
    [double]$saveIntervalHours = 6,
    [ValidateSet("compressed", "uncompressed", "both")]
    [string]$mode = "uncompressed",
    [int]$restartDelaySeconds = 30
)

$wrapperDir  = "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers"
$scanScript  = Join-Path $wrapperDir "v3.ps1"
$logFile     = Join-Path $wrapperDir "runner.log"
$mutexName   = "Global\KeyHuntSegmentScanner"

function Log($m) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

if (!(Test-Path $scanScript)) {
    Log "ERROR: Scan script not found: $scanScript"
    exit 1
}

# Prevent duplicate runners (e.g. Task Scheduler + manual start)
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
try {
    $createdNew = $mutex.WaitOne(0)
}
catch {
    Log "ERROR: Could not acquire runner lock: $($_.Exception.Message)"
    exit 1
}

if (!$createdNew) {
    Log "Another runner is already active. Exiting."
    exit 0
}

Log "Runner started (PID $PID) | floor SEG $startIndex | saveInterval ${saveIntervalHours}h"

while ($true) {
    try {
        Log "Launching scan script..."

        $argList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $scanScript,
            "-startIndex", $startIndex,
            "-saveIntervalHours", $saveIntervalHours,
            "-mode", $mode
        )

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -NoNewWindow -Wait -PassThru
        $code = $proc.ExitCode

        if ($code -eq 0) {
            Log "Scan finished normally (all segments complete). Runner stopping."
            break
        }

        Log "Scan exited with code $code. Restarting in $restartDelaySeconds second(s)..."
    }
    catch {
        Log "ERROR: $($_.Exception.Message). Restarting in $restartDelaySeconds second(s)..."
    }

    Start-Sleep -Seconds $restartDelaySeconds
}

Log "Runner stopped."
$mutex.ReleaseMutex()
