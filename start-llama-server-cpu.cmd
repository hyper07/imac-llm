@echo off
REM Double-click this to start the local LLM backend on the CPU.
REM Use this until the AMD Boot Camp R6.4 driver is installed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-llama-server-cpu.ps1"
pause
