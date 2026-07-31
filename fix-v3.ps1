# Run once to patch v3.ps1 for Windows PowerShell 5.1
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\fix-v3.ps1"

$path = Join-Path $PSScriptRoot "v3.ps1"
if (-not (Test-Path $path)) {
    $path = "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1"
}
if (-not (Test-Path $path)) {
    Write-Host "v3.ps1 not found." -ForegroundColor Red
    exit 1
}

Copy-Item $path "$path.bak" -Force
$c = Get-Content $path -Raw -Encoding UTF8
$orig = $c

$c = $c -replace 'SEG \$segIdx:', 'SEG ${segIdx}:'
$c = $c -replace "ContainsKey\('startSub'\)", 'ContainsKey("startSub")'

$c = $c -replace '(?ms)^\s*Add-Content -Path \$foundLog -Value "\[\$stamp\] SEG \$segIdx SUB \$s \| \$hit"\s*\r?\n', @"
                            `$foundMsg = "[{0}] SEG {1} SUB {2} | {3}" -f `$stamp, `$segIdx, `$s, `$hit
                            Add-Content -Path `$foundLog -Value `$foundMsg
"@

$c = $c -replace 'Info "v3 \| segments: \$\(\$segments\.Count\) \| floor: \$floorIndex \| checkpoint: \$\{saveIntervalHours\}h"', @'
    Info ("v3 | segments: {0} | floor: {1} | checkpoint: {2}h" -f $segments.Count, $floorIndex, $saveIntervalHours)'@

$c = $c -replace 'Info "SEG \$segIdx \$\(\$range\.Start\):\$\(\$range\.End\) \| SUB \$subStart[^\r\n]*"', @'
        Info ("SEG {0} {1}:{2} | SUB {3}-{4}" -f $segIdx, $range.Start, $range.End, $subStart, ($subCount - 1))'@

$c = $c -replace 'Log "v3 started \| startIndex=\$startIndex \| saveInterval=\$\{saveIntervalHours\}h \| mode=\$mode"', @'
Log ("v3 started | startIndex={0} | saveInterval={1}h | mode={2}" -f $startIndex, $saveIntervalHours, $mode)'@

if ($c -eq $orig) {
    Write-Host "No changes needed (already patched?) or patterns not found." -ForegroundColor Yellow
    Write-Host "Check line 468 manually. Backup: $path.bak"
    exit 1
}

[System.IO.File]::WriteAllText($path, $c, [System.Text.UTF8Encoding]::new($false))
Write-Host "Patched: $path" -ForegroundColor Green
Write-Host "Backup:  $path.bak"
Write-Host ""
Write-Host "Now run:" -ForegroundColor Cyan
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$path`" -startIndex 7790 -saveIntervalHours 6 -RegisterAutoStart"
