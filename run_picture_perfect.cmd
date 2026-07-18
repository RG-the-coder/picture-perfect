@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_picture_perfect.ps1" %*
set "PICTURE_PERFECT_EXIT=%ERRORLEVEL%"
if not "%PICTURE_PERFECT_EXIT%"=="0" (
  echo.
  echo Picture Perfect did not start. The specific error is shown above.
)
exit /b %PICTURE_PERFECT_EXIT%
