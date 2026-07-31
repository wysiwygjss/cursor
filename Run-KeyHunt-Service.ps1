# Launcher alias — forwards all arguments to v3.ps1
$v3 = Join-Path $PSScriptRoot "v3.ps1"
if (!(Test-Path $v3)) {
    $v3 = "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1"
}
if (!(Test-Path $v3)) {
    Write-Host "v3.ps1 not found next to this script." -ForegroundColor Red
    exit 1
}

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $v3 @args
