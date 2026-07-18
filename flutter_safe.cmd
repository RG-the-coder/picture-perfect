@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flutter_safe.ps1" %*
exit /b %ERRORLEVEL%
