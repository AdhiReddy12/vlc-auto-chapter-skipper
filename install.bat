@echo off
echo ============================================
echo   Auto Chapter Skipper - Windows Installer
echo ============================================
echo.
echo Launching PowerShell installer...
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1"

echo.
pause
