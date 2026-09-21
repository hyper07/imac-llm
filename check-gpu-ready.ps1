# Run this AFTER installing the AMD Boot Camp R6.4 driver and rebooting.
# It reports whether llama.cpp can now use the Radeon Pro 580.

$Root  = "C:\llama-vulkan"
$Model = Join-Path $Root "models\Qwen3-8B-Q4_K_M.gguf"

Write-Host "=== Installed display driver ===" -ForegroundColor Cyan
Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { $_.DeviceName -like "*Radeon*" } |
    Select-Object DeviceName, DriverVersion, DriverDate |
    Format-List

Write-Host "=== Vulkan API version ===" -ForegroundColor Cyan
(vulkaninfo --summary 2>$null | Select-String "apiVersion|deviceName")

Write-Host "`n=== llama.cpp GPU probe ===" -ForegroundColor Cyan
# The old driver failed here with: "device Vulkan0 does not support 16-bit storage."
# llama-server logs to stderr; redirecting it inline would make PowerShell raise
# NativeCommandError on every line, so capture through a temp file instead.
$tmp = Join-Path $env:TEMP "llama-probe.txt"
Start-Process -FilePath (Join-Path $Root "llama-server.exe") `
    -ArgumentList '--model', "`"$Model`"", '--n-gpu-layers', '99', '--list-devices' `
    -NoNewWindow -Wait -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err"
$out = ((Get-Content $tmp -Raw -ErrorAction SilentlyContinue) +
        (Get-Content "$tmp.err" -Raw -ErrorAction SilentlyContinue)) | Out-String
Write-Host $out

if ($out -match "does not support 16-bit storage") {
    Write-Host "RESULT: still blocked - driver did not expose storageBuffer16BitAccess." -ForegroundColor Red
    Write-Host "Keep using start-llama-server-cpu.cmd." -ForegroundColor Yellow
} elseif ($out -match "Vulkan0") {
    Write-Host "RESULT: GPU is usable. Run start-llama-server.cmd instead of the CPU one." -ForegroundColor Green
} else {
    Write-Host "RESULT: no Vulkan device found - check the driver install." -ForegroundColor Red
}
