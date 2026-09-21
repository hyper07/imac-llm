@echo off
REM Starts the model with Qwen3's reasoning ENABLED (slower, shows a Thinking
REM block in Open WebUI). Stop the normal server first - both use port 8080.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-llama-server.ps1" -Thinking
pause
