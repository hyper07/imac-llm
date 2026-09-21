@echo off
REM Launches the AMD Boot Camp R6.4 installer elevated.
REM The screen will flicker or go black during install - this is expected.
REM Reboot afterwards, then run check-gpu-ready.ps1.
set "SETUP=%~dp0driver\unified_r6.4_21.30.45.22_whql_250611a-418524C\Setup.exe"
if not exist "%SETUP%" (
    echo Setup.exe not found at "%SETUP%"
    pause
    exit /b 1
)
powershell.exe -NoProfile -Command "Start-Process -FilePath '%SETUP%' -Verb RunAs"
