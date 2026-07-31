# One-time setup — auto-start after reboot (optional):
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\Register-KeyHunt-Startup.ps1"

param(
    [int]$startIndex = 7790,
    [double]$saveIntervalHours = 6,
    [string]$taskName = "KeyHunt Segment Scanner"
)

$wrapperDir = "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers"
$runnerScript = Join-Path $wrapperDir "Run-KeyHunt-Service.ps1"

if (!(Test-Path $runnerScript)) {
    Write-Host "ERROR: Runner not found: $runnerScript" -ForegroundColor Red
    exit 1
}

$argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runnerScript`" -startIndex $startIndex -saveIntervalHours $saveIntervalHours"

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argString -WorkingDirectory $wrapperDir

$triggerBoot = New-ScheduledTaskTrigger -AtStartup
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed existing task '$taskName'"
}

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerBoot, $triggerLogon) `
    -Settings $settings `
    -Principal $principal `
    -Description "Auto-start KeyHunt segment scanner after reboot; resumes from resume files in Scanned_Segments"

Write-Host "Registered task '$taskName'" -ForegroundColor Green
Write-Host "  Runner: $runnerScript"
Write-Host "  Args:   $argString"
Write-Host ""
Write-Host "Test now:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
Write-Host ""
Write-Host "Remove task:" -ForegroundColor Cyan
Write-Host "  Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
